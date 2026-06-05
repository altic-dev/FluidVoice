import Foundation

final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice"
    var isAvailable: Bool { true }
    private(set) var isReady = false
    var prefersNativeFileTranscription: Bool { true }

    private struct SenseVoiceCLIResult: Decodable {
        let text: String
        let emotion: String?
        let event: String?
    }

    private enum Constants {
        static let folderName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        static let archiveName = "\(folderName).tar.bz2"
        static let archiveURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(archiveName)")!
        static let modelFile = "model.int8.onnx"
        static let tokensFile = "tokens.txt"
        static let executableDefaultsKey = "SenseVoiceSherpaOnnxExecutablePath"
    }

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Constants.folderName, isDirectory: true)
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }
        guard let directory = self.cacheDirectory else {
            throw Self.makeError("Unable to resolve a cache directory for SenseVoice.")
        }

        if self.modelsExistOnDisk() {
            progressHandler?(1.0)
            self.isReady = true
            return
        }

        try await self.downloadAndExtractModel(to: directory, progressHandler: progressHandler)
        guard self.modelsExistOnDisk() else {
            throw Self.makeError("SenseVoice model files are incomplete after download.")
        }
        self.isReady = true
        progressHandler?(1.0)
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard samples.count >= 16_000 else {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        let previewSamples = samples.count > 160_000 ? Array(samples.suffix(160_000)) : samples
        return try await self.transcribeFinal(previewSamples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard samples.isEmpty == false else {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        guard self.modelsExistOnDisk(), let directory = self.cacheDirectory else {
            throw Self.makeError("SenseVoice model is not downloaded.")
        }
        let executableURL = try Self.resolveSherpaExecutable()
        let wavURL = try Self.writeTemporaryWAV(samples: samples)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let result = try Self.runSherpa(
            executableURL: executableURL,
            modelDirectory: directory,
            wavURL: wavURL
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        guard self.modelsExistOnDisk(), let directory = self.cacheDirectory else {
            throw Self.makeError("SenseVoice model is not downloaded.")
        }
        let executableURL = try Self.resolveSherpaExecutable()
        let result = try Self.runSherpa(
            executableURL: executableURL,
            modelDirectory: directory,
            wavURL: fileURL
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
    }

    func modelsExistOnDisk() -> Bool {
        guard let directory = self.cacheDirectory else { return false }
        return [
            Constants.modelFile,
            Constants.tokensFile,
        ].allSatisfy { entry in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry).path)
        }
    }

    func clearCache() async throws {
        if let directory = self.cacheDirectory,
           FileManager.default.fileExists(atPath: directory.path)
        {
            try FileManager.default.removeItem(at: directory)
        }
        self.isReady = false
    }

    private func downloadAndExtractModel(to directory: URL, progressHandler: ((Double) -> Void)?) async throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let archiveURL = parent.appendingPathComponent(Constants.archiveName, isDirectory: false)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let delegate = DownloadProgressDelegate { progress in
            progressHandler?(progress * 0.85)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: Constants.archiveURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.onFinish = { temporaryURL, response in
                do {
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        throw Self.makeError("SenseVoice download failed with HTTP \(http.statusCode).")
                    }
                    if FileManager.default.fileExists(atPath: archiveURL.path) {
                        try FileManager.default.removeItem(at: archiveURL)
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            delegate.onError = { error in
                continuation.resume(throwing: error)
            }
            task.resume()
        }

        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        progressHandler?(0.9)
        try Self.extractArchive(archiveURL, into: parent)
        progressHandler?(0.98)
    }

    private static func extractArchive(_ archiveURL: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", archiveURL.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Self.makeError("Failed to extract SenseVoice model archive.")
        }
    }

    private static func resolveSherpaExecutable() throws -> URL {
        if let explicitPath = UserDefaults.standard.string(forKey: Constants.executableDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            explicitPath.isEmpty == false,
            FileManager.default.isExecutableFile(atPath: explicitPath)
        {
            return URL(fileURLWithPath: explicitPath)
        }

        let candidates = [
            "/opt/homebrew/bin/sherpa-onnx-offline",
            "/usr/local/bin/sherpa-onnx-offline",
            "/usr/bin/sherpa-onnx-offline",
        ]
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: match)
        }

        throw Self.makeError(
            "SenseVoice requires sherpa-onnx-offline. Install sherpa-onnx or set the \(Constants.executableDefaultsKey) default to the executable path."
        )
    }

    private static func runSherpa(
        executableURL: URL,
        modelDirectory: URL,
        wavURL: URL
    ) throws -> SenseVoiceCLIResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--tokens=\(modelDirectory.appendingPathComponent(Constants.tokensFile).path)",
            "--sense-voice-model=\(modelDirectory.appendingPathComponent(Constants.modelFile).path)",
            "--sense-voice-language=en",
            "--num-threads=2",
            "--sense-voice-use-itn=1",
            "--debug=0",
            wavURL.path,
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errorOutput.isEmpty ? output : errorOutput
            throw Self.makeError("SenseVoice transcription failed: \(message)")
        }

        for line in output.components(separatedBy: .newlines).reversed() {
            guard line.contains("\"text\""), let data = line.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode(SenseVoiceCLIResult.self, from: data) {
                return decoded
            }
        }

        throw Self.makeError("SenseVoice did not return a parseable transcription result.")
    }

    private static func writeTemporaryWAV(samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensevoice-\(UUID().uuidString).wav", isDirectory: false)
        var data = Data()
        let pcm = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }
        let dataBytes = UInt32(pcm.count * MemoryLayout<Int16>.size)

        data.append(contentsOf: "RIFF".utf8)
        data.append(UInt32(36 + dataBytes).littleEndianData)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt32(16_000).littleEndianData)
        data.append(UInt32(16_000 * 2).littleEndianData)
        data.append(UInt16(2).littleEndianData)
        data.append(UInt16(16).littleEndianData)
        data.append(contentsOf: "data".utf8)
        data.append(dataBytes.littleEndianData)
        pcm.withUnsafeBufferPointer { buffer in
            let rawBuffer = UnsafeRawBufferPointer(buffer)
            if let baseAddress = rawBuffer.baseAddress {
                data.append(Data(bytes: baseAddress, count: rawBuffer.count))
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(domain: "SenseVoiceProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        private let onProgress: ((Double) -> Void)?
        var onFinish: ((URL, URLResponse) -> Void)?
        var onError: ((Error) -> Void)?

        init(onProgress: ((Double) -> Void)?) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let response = downloadTask.response else { return }
            self.onFinish?(location, response)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { self.onError?(error) }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            self.onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
