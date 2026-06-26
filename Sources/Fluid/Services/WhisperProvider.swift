import Foundation
import SwiftWhisper

/// TranscriptionProvider implementation using SwiftWhisper (whisper.cpp) for Intel Macs.
/// This provides on-device speech recognition that works on Intel x86_64 architecture.
final class WhisperProvider: TranscriptionProvider {
    let name = "Whisper (Intel/Universal)"

    /// Whether this provider is supported on the current system.
    /// SwiftWhisper (whisper.cpp) works on both Intel and Apple Silicon.
    var isAvailable: Bool {
        true
    }

    private var whisper: Whisper?
    private(set) var isReady: Bool = false
    private var loadedModelName: String?

    private let overriddenModelDirectory: URL?
    private let urlSession: URLSession

    /// Optional model override - if set, uses this model instead of the global setting.
    /// Used for downloading specific models without changing the active selection.
    var modelOverride: SettingsStore.SpeechModel?

    init(modelDirectory: URL? = nil, urlSession: URLSession = .shared, modelOverride: SettingsStore.SpeechModel? = nil) {
        self.overriddenModelDirectory = modelDirectory
        self.urlSession = urlSession
        self.modelOverride = modelOverride
    }

    /// Model filename to use - reads from override first, then unified SpeechModel setting
    /// Models: tiny (~75MB), base (~142MB), small (~466MB), medium (~1.5GB), large (~2.9GB)
    private var modelName: String {
        let model = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        let configured = model.whisperModelFile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return configured
        }
        return "ggml-base.bin"
    }

    private var modelURL: URL {
        let directory: URL
        if let overriddenModelDirectory {
            directory = overriddenModelDirectory
        } else {
            guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                preconditionFailure("Could not find caches directory")
            }
            directory = cacheDir.appendingPathComponent("WhisperModels")
        }

        return directory.appendingPathComponent(self.modelName)
    }

    private var modelDirectory: URL {
        self.modelURL.deletingLastPathComponent()
    }

    private func expectedMinimumModelBytes(for fileName: String) -> Int64? {
        switch fileName {
        case "ggml-tiny.bin":
            return 50 * 1024 * 1024
        case "ggml-base.bin":
            return 100 * 1024 * 1024
        case "ggml-small.bin":
            return 300 * 1024 * 1024
        case "ggml-medium.bin":
            return 1000 * 1024 * 1024
        // case "ggml-large-v3-turbo.bin": // buggy - so removed temporarily
        //     return 1200 * 1024 * 1024
        case "ggml-large-v3.bin":
            return 2000 * 1024 * 1024
        default:
            return nil
        }
    }

    private func isModelFileValid(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        let sizeBytes = size.int64Value
        guard sizeBytes > 0 else { return false }
        if let minBytes = self.expectedMinimumModelBytes(for: url.lastPathComponent),
           sizeBytes < minBytes
        {
            return false
        }
        return true
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        // CRITICAL: Capture the target model at start to use consistently throughout this method.
        // This prevents race conditions where SettingsStore could change after await points.
        let targetModel = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        let currentModelName = targetModel.whisperModelFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ggml-base.bin"

        // Detect model change: if a different model is now selected, force reload
        if self.isReady, self.loadedModelName != currentModelName {
            DebugLogger.shared.info("WhisperProvider: Model changed from \(self.loadedModelName ?? "nil") to \(currentModelName), forcing reload", source: "WhisperProvider")
            self.isReady = false
            self.whisper = nil
            self.loadedModelName = nil
        }

        guard self.isReady == false else { return }

        DebugLogger.shared.info("WhisperProvider: Starting model preparation", source: "WhisperProvider")

        // Ensure model directory exists
        try FileManager.default.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: self.modelURL.path),
           !self.isModelFileValid(at: self.modelURL)
        {
            DebugLogger.shared.warning(
                "WhisperProvider: Found invalid model file at \(self.modelURL.path); removing to force re-download",
                source: "WhisperProvider"
            )
            try? FileManager.default.removeItem(at: self.modelURL)
        }

        // Download model if not present
        if !FileManager.default.fileExists(atPath: self.modelURL.path) {
            DebugLogger.shared.info("WhisperProvider: Downloading Whisper model...", source: "WhisperProvider")
            try await self.downloadModel(progressHandler: progressHandler)
        }

        guard self.isModelFileValid(at: self.modelURL) else {
            throw NSError(
                domain: "WhisperProvider",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model file is missing or corrupted. Please re-download the model."]
            )
        }

        // Check available memory before loading large models
        // Use the captured targetModel to ensure consistent memory validation
        let requiredMemoryGB = targetModel.requiredMemoryGB
        let availableMemoryGB = Self.availableMemoryGB()

        DebugLogger.shared.info(
            "WhisperProvider: Memory check - Required: \(String(format: "%.1f", requiredMemoryGB))GB, Available: \(String(format: "%.1f", availableMemoryGB))GB",
            source: "WhisperProvider"
        )

        if availableMemoryGB < requiredMemoryGB {
            let errorMessage = """
            Insufficient memory for \(targetModel.displayName).
            Required: \(String(format: "%.1f", requiredMemoryGB)) GB
            Available: \(String(format: "%.1f", availableMemoryGB)) GB

            Please try a smaller model (e.g., Whisper Base or Small) or close other applications to free up memory.
            """

            DebugLogger.shared.error("WhisperProvider: \(errorMessage)", source: "WhisperProvider")

            throw NSError(
                domain: "WhisperProvider",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        // Load the model
        DebugLogger.shared.info("WhisperProvider: Loading Whisper model...", source: "WhisperProvider")
        self.whisper = Whisper(fromFileURL: self.modelURL)

        self.loadedModelName = currentModelName
        self.isReady = true
        DebugLogger.shared.info("WhisperProvider: Model ready (\(currentModelName))", source: "WhisperProvider")
    }

    /// Returns the available system memory in GB
    private static func availableMemoryGB() -> Double {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            // Fallback: assume we have enough memory if we can't check
            DebugLogger.shared.warning("WhisperProvider: Failed to get memory stats, assuming sufficient memory", source: "WhisperProvider")
            return 16.0
        }

        // Calculate free + inactive memory (memory that can be reclaimed)
        let freePages = UInt64(vmStats.free_count)
        let inactivePages = UInt64(vmStats.inactive_count)
        let purgablePages = UInt64(vmStats.purgeable_count)

        let availableBytes = (freePages + inactivePages + purgablePages) * UInt64(pageSize)
        let availableGB = Double(availableBytes) / (1024 * 1024 * 1024)

        return availableGB
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        // Whisper.cpp asserts on very short buffers; guard early to avoid abort.
        let minSamples = 16_000
        guard samples.count >= minSamples else {
            throw NSError(
                domain: "WhisperProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio too short for Whisper transcription"]
            )
        }

        guard let whisper = whisper else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded"]
            )
        }

        // SwiftWhisper expects 16kHz PCM audio frames (which is what we receive)
        let segments = try await whisper.transcribe(audioFrames: samples)

        // Combine all segments into one string
        let fullText = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // SwiftWhisper doesn't provide confidence, so we use 1.0
        return ASRTranscriptionResult(text: fullText, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        return self.isModelFileValid(at: self.modelURL)
    }

    func clearCache() async throws {
        if FileManager.default.fileExists(atPath: self.modelURL.path) {
            try FileManager.default.removeItem(at: self.modelURL)
        }
        if FileManager.default.fileExists(atPath: self.modelDirectory.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: self.modelDirectory.path)
            if contents.isEmpty {
                try FileManager.default.removeItem(at: self.modelDirectory)
            }
        }
        self.isReady = false
        self.whisper = nil
        self.loadedModelName = nil
    }

    // MARK: - Model Download

    private func downloadModel(progressHandler: ((Double) -> Void)?) async throws {
        // Whisper models are hosted on Hugging Face
        let modelURLString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)"

        guard let url = URL(string: modelURLString) else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid model URL"]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Downloading from \(modelURLString)", source: "WhisperProvider")

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                if attempt == 1 {
                    progressHandler?(0.0)
                }

                try await self.downloadFile(from: url, to: self.modelURL, progressHandler: progressHandler)

                DebugLogger.shared.info("WhisperProvider: Model downloaded successfully", source: "WhisperProvider")
                return
            } catch let error as NSError {
                let isLastAttempt = attempt == maxAttempts

                // Provide user-friendly error messages
                if error.domain == NSURLErrorDomain {
                    let message: String
                    switch error.code {
                    case NSURLErrorNotConnectedToInternet:
                        message = "No internet connection. Please connect to the internet to download the Whisper model."
                    case NSURLErrorTimedOut:
                        message = "Download timed out. Please check your internet connection and try again."
                    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                        message = "Cannot reach download server. Please check your internet connection."
                    default:
                        message = "Network error: \(error.localizedDescription)"
                    }

                    if isLastAttempt {
                        throw NSError(
                            domain: "WhisperProvider",
                            code: error.code,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }

                    DebugLogger.shared.warning(
                        "WhisperProvider: Download attempt \(attempt)/\(maxAttempts) failed (\(message)). Retrying...",
                        source: "WhisperProvider"
                    )
                } else {
                    if isLastAttempt { throw error }
                    DebugLogger.shared.warning(
                        "WhisperProvider: Download attempt \(attempt)/\(maxAttempts) failed (\(error.localizedDescription)). Retrying...",
                        source: "WhisperProvider"
                    )
                }

                // Backoff: 1s, 2s, 4s
                let delayNanos = UInt64(1_000_000_000) << UInt64(attempt - 1)
                try await Task.sleep(nanoseconds: delayNanos)
            }
        }
    }

    private func downloadFile(from url: URL, to destination: URL, progressHandler: ((Double) -> Void)?) async throws {
        let delegate = DownloadProgressDelegate(onProgress: progressHandler)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var didResume = false

            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                session.finishTasksAndInvalidate()
                continuation.resume(with: result)
            }

            delegate.onFinish = { tempURL, response in
                do {
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(
                            domain: "WhisperProvider",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid server response"]
                        )
                    }

                    guard httpResponse.statusCode == 200 else {
                        throw NSError(
                            domain: "WhisperProvider",
                            code: httpResponse.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to download model (HTTP \(httpResponse.statusCode))"]
                        )
                    }

                    if httpResponse.expectedContentLength > 0 {
                        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                        if let size = attrs[.size] as? NSNumber,
                           size.int64Value != httpResponse.expectedContentLength
                        {
                            throw NSError(
                                domain: "WhisperProvider",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Downloaded model size mismatch. Please try again."]
                            )
                        }
                    }

                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)

                    if !self.isModelFileValid(at: destination) {
                        try? FileManager.default.removeItem(at: destination)
                        throw NSError(
                            domain: "WhisperProvider",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Downloaded model is invalid. Please try again."]
                        )
                    }
                    resumeOnce(.success(()))
                } catch {
                    resumeOnce(.failure(error))
                }
            }
            delegate.onError = { error in
                resumeOnce(.failure(error))
            }
            task.resume()
        }
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
            if let error = error { self.onError?(error) }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            self.onProgress?(pct)
        }
    }
}
