import Foundation
import AVFoundation

// MARK: - Cloud ASR Provider

/// A TranscriptionProvider that uses cloud-based Speech-to-Text APIs.
/// Supports OpenAI Whisper API, Azure Speech Services, Google Cloud Speech-to-Text, and custom OpenAI-compatible endpoints.
final class CloudASRProvider: TranscriptionProvider {
    let name = "Cloud Speech API"

    /// Always available (requires internet connection)
    var isAvailable: Bool {
        true
    }

    private(set) var isReady: Bool = false
    private var urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Configuration

    private var config: CloudASRConfig {
        SettingsStore.shared.cloudASRConfig
    }

    // MARK: - Lifecycle

    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        let config = self.config

        // Validate configuration
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "CloudASRProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "API Key not configured. Please set it in Settings."]
            )
        }

        // For custom endpoints, validate baseURL
        if config.provider == "custom" {
            guard let baseURL = config.baseURL, !baseURL.isEmpty else {
                throw NSError(
                    domain: "CloudASRProvider",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Base URL not configured for custom provider"]
                )
            }
        }

        self.isReady = true
        DebugLogger.shared.info("CloudASRProvider ready (provider=\(config.provider))", source: "CloudASRProvider")
    }

    func modelsExistOnDisk() -> Bool {
        true // Cloud models don't need local storage
    }

    func clearCache() async throws {
        // No cache for cloud API
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isReady else {
            throw NSError(
                domain: "CloudASRProvider",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Provider not ready. Call prepare() first."]
            )
        }

        let config = self.config

        // Route to appropriate provider
        switch config.provider {
        case "openai":
            return try await transcribeWithOpenAI(samples: samples, config: config)
        case "azure":
            return try await transcribeWithAzure(samples: samples, config: config)
        case "google":
            return try await transcribeWithGoogle(samples: samples, config: config)
        case "custom":
            return try await transcribeWithCustom(samples: samples, config: config)
        default:
            throw NSError(
                domain: "CloudASRProvider",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unknown provider: \(config.provider)"]
            )
        }
    }

    // MARK: - OpenAI Whisper API

    private func transcribeWithOpenAI(samples: [Float], config: CloudASRConfig) async throws -> ASRTranscriptionResult {
        DebugLogger.shared.info("CloudASRProvider: Using OpenAI Whisper API", source: "CloudASRProvider")

        // Convert audio to the format expected by OpenAI
        let audioData = try convertAudioToM4A(samples: samples)

        // Create request
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("multipart/form-data", forHTTPHeaderField: "Content-Type")

        // Build multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model parameter
        let modelName = config.model.isEmpty ? "whisper-1" : config.model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(modelName)\r\n".data(using: .utf8)!)

        // Add language parameter if specified
        if let language = config.language, !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        // Add response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        // Send request
        let (data, response) = try await urlSession.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "CloudASRProvider", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            DebugLogger.shared.error("OpenAI API error HTTP \(httpResponse.statusCode): \(errorMessage)", source: "CloudASRProvider")
            throw NSError(
                domain: "CloudASRProvider",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API error: \(errorMessage)"]
            )
        }

        // Parse response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            DebugLogger.shared.debug("OpenAI Whisper result: '\(text)'", source: "CloudASRProvider")
            return ASRTranscriptionResult(text: text, confidence: 1.0)
        }

        throw NSError(domain: "CloudASRProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to parse response"])
    }

    // MARK: - Azure Speech Services

    private func transcribeWithAzure(samples: [Float], config: CloudASRConfig) async throws -> ASRTranscriptionResult {
        DebugLogger.shared.info("CloudASRProvider: Using Azure Speech Services", source: "CloudASRProvider")

        // Azure Speech API requires audio in a specific format
        let audioData = try convertAudioToWAV(samples: samples)

        // Build endpoint URL
        let baseURL = config.baseURL ?? "https://<region>.api.cognitive.microsoft.com"
        let url = URL(string: "\(baseURL)/speech/recognition/conversation/v3")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Ocp-Apim-Subscription-Key: \(config.apiKey)", forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.addValue("audio/wav", forHTTPHeaderField: "Content-Type")

        request.httpBody = audioData

        let (data, response) = try await urlSession.upload(for: request, from: audioData)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "CloudASRProvider",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Azure API error: \(errorMessage)"]
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["DisplayText"] as? String {
            return ASRTranscriptionResult(text: text, confidence: 1.0)
        }

        throw NSError(domain: "CloudASRProvider", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Azure response"])
    }

    // MARK: - Google Cloud Speech-to-Text

    private func transcribeWithGoogle(samples: [Float], config: CloudASRConfig) async throws -> ASRTranscriptionResult {
        DebugLogger.shared.info("CloudASRProvider: Using Google Cloud Speech-to-Text", source: "CloudASRProvider")

        // Convert to base64-encoded WAV/FLAC
        let audioData = try convertAudioToWAV(samples: samples)
        let base64Audio = audioData.base64EncodedString()

        // Build request
        let url = URL(string: "https://speech.googleapis.com/v1/speech:recognize?key=\(config.apiKey)")!

        let requestBody: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": 16000,
                "languageCode": config.language ?? "zh-CN",
                "enableAutomaticPunctuation": true
            ],
            "audio": [
                "content": base64Audio
            ]
        ]

        let requestData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData

        let (data, response) = try await urlSession.upload(for: request, from: requestData)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "CloudASRProvider",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Google API error: \(errorMessage)"]
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let firstResult = results.first,
           let alternatives = firstResult["alternatives"] as? [[String: Any]],
           let firstAlternative = alternatives.first,
           let transcript = firstAlternative["transcript"] as? String {
            return ASRTranscriptionResult(text: transcript, confidence: 1.0)
        }

        throw NSError(domain: "CloudASRProvider", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Google response"])
    }

    // MARK: - Custom OpenAI-Compatible API

    private func transcribeWithCustom(samples: [Float], config: CloudASRConfig) async throws -> ASRTranscriptionResult {
        DebugLogger.shared.info("CloudASRProvider: Using custom endpoint (baseURL=\(config.baseURL ?? "N/A"), model=\(config.model))", source: "CloudASRProvider")

        guard let baseURL = config.baseURL, !baseURL.isEmpty else {
            throw NSError(domain: "CloudASRProvider", code: 11, userInfo: [NSLocalizedDescriptionKey: "Base URL not configured"])
        }

        let sampleRate = 16000.0

        let actualDuration = Double(samples.count) / sampleRate
        DebugLogger.shared.debug("CloudASRProvider: Audio duration=\(String(format: "%.2f", actualDuration))s, samples=\(samples.count)", source: "CloudASRProvider")

        // Use WAV format (more universally supported than M4A)
        let audioData = try convertAudioToWAV(samples: samples)
        let fileExtension = "wav"
        let mimeType = "audio/wav"

        DebugLogger.shared.debug("CloudASRProvider: Audio converted to WAV, size=\(audioData.count) bytes", source: "CloudASRProvider")

        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Add auth header if not a local endpoint
        if !isLocalEndpoint(baseURL) {
            request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Build multipart form data (similar to OpenAI but with WAV)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(fileExtension)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model parameter
        let modelName = config.model.isEmpty ? "whisper-1" : config.model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(modelName)\r\n".data(using: .utf8)!)

        // Add language parameter if specified
        if let language = config.language, !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        // Add response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        DebugLogger.shared.debug("CloudASRProvider: Sending request to \(url.absoluteString), body size=\(body.count) bytes", source: "CloudASRProvider")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "CloudASRProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            DebugLogger.shared.error("Custom API error HTTP \(httpResponse.statusCode): \(errorMessage)", source: "CloudASRProvider")
            throw NSError(
                domain: "CloudASRProvider",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API error: \(errorMessage)"]
            )
        }

        // Log raw response for debugging
        let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode"
        DebugLogger.shared.debug("CloudASRProvider: Raw API response: \(rawResponse)", source: "CloudASRProvider")

        // Try to parse response (handle different formats)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Try common field names for transcription result
            let text = json["text"] as? String
                   ?? json["transcription"] as? String
                   ?? json["result"] as? String
                   ?? json["content"] as? String

            if let text = text, !text.isEmpty {
                DebugLogger.shared.debug("CloudASRProvider: Parsed result: '\(text)'", source: "CloudASRProvider")
                return ASRTranscriptionResult(text: text, confidence: 1.0)
            }

            // Log all available keys for debugging
            let keys = json.keys.joined(separator: ", ")
            DebugLogger.shared.error("CloudASRProvider: No text field found in response. Available keys: \(keys)", source: "CloudASRProvider")
        }

        throw NSError(domain: "CloudASRProvider", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to parse custom API response. Raw: \(rawResponse)"])
    }

    // MARK: - Audio Conversion Helpers

    /// Convert raw PCM samples to M4A format for cloud APIs
    private func convertAudioToM4A(samples: [Float]) throws -> Data {
        // Create AVAudioFormat for 16kHz mono
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw NSError(domain: "CloudASRProvider", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "CloudASRProvider", code: 21, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "CloudASRProvider", code: 22, userInfo: [NSLocalizedDescriptionKey: "Failed to get channel data"])
        }

        samples.withUnsafeBufferPointer { samplePtr in
            guard let baseAddress = samplePtr.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }

        // Convert to M4A using AVAudioFile
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("audio_\(UUID().uuidString).m4a")

        guard let audioFile = try? AVAudioFile(
            forWriting: tempURL,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        ) else {
            throw NSError(domain: "CloudASRProvider", code: 23, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio file"])
        }

        try audioFile.write(from: buffer)

        let audioData = try Data(contentsOf: tempURL)

        // Clean up temp file
        try? FileManager.default.removeItem(at: tempURL)

        return audioData
    }

    /// Convert raw PCM samples to WAV format for Azure/Google
    private func convertAudioToWAV(samples: [Float]) throws -> Data {
        // WAV file header (44 bytes)
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign: UInt16 = numChannels * bitsPerSample / 8
        let dataSize: UInt32 = UInt32(samples.count) * UInt32(bitsPerSample) / 8
        let fileSize: UInt32 = 36 + dataSize

        var wav = Data()

        // RIFF header
        wav.append("RIFF".data(using: .utf8)!)
        wav.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .utf8)!)

        // fmt chunk
        wav.append("fmt ".data(using: .utf8)!)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // chunk size
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // audio format (PCM)
        wav.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data chunk
        wav.append("data".data(using: .utf8)!)
        wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        // Convert float samples to 16-bit PCM
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            wav.append(withUnsafeBytes(of: int16.littleEndian) { Data($0) })
        }

        return wav
    }

    // MARK: - Helper Methods

    private func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else { return false }

        let hostLower = host.lowercased()

        if hostLower == "localhost" || hostLower == "127.0.0.1" {
            return true
        }

        if hostLower.hasPrefix("127.") {
            return true
        }

        if hostLower.hasPrefix("10.") {
            return true
        }

        if hostLower.hasPrefix("192.168.") {
            return true
        }

        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16 && secondOctet <= 31 {
                return true
            }
        }

        return false
    }
}

// MARK: - Cloud ASR Configuration

/// Configuration for cloud-based ASR providers
struct CloudASRConfig: Codable {
    var provider: String           // "openai", "azure", "google", "custom"
    var apiKey: String            // API key for the service
    var baseURL: String?          // Custom endpoint URL (for custom provider)
    var model: String             // Model name (e.g., "whisper-1")
    var language: String?         // Language code (e.g., "zh", "en")

    init(
        provider: String = "openai",
        apiKey: String = "",
        baseURL: String? = nil,
        model: String = "whisper-1",
        language: String? = nil
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.language = language
    }

    /// Default configuration for OpenAI
    static let openAI = CloudASRConfig(
        provider: "openai",
        model: "whisper-1",
        language: "zh"
    )

    /// Default configuration for Azure
    static let azure = CloudASRConfig(
        provider: "azure",
        model: "",
        language: "zh-CN"
    )

    /// Default configuration for Google
    static let google = CloudASRConfig(
        provider: "google",
        model: "",
        language: "zh-CN"
    )
}
