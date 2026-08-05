import Foundation
import TranscribeCpp

/// TranscriptionProvider implementation using transcribe.cpp for Whisper GGUF models.
final class WhisperProvider: TranscriptionProvider {
    let name = "Whisper (Universal)"

    var isAvailable: Bool {
        guard case .success = Self.backendInitialization else { return false }
        if CPUArchitecture.isAppleSilicon {
            return Transcribe.backendAvailable(.metal)
        }
        return Transcribe.backendAvailable(.cpu)
    }

    private static let backendInitialization: Result<Void, Error> = Result {
        try Transcribe.initBackends()
    }

    private let stateLock = NSLock()
    private var model: Model?
    private var session: Session?
    private var ready = false
    private var loadedModelName: String?

    private let overriddenModelDirectory: URL?
    private let urlSession: URLSession

    var modelOverride: SettingsStore.SpeechModel?

    init(modelDirectory: URL? = nil, urlSession: URLSession = .shared, modelOverride: SettingsStore.SpeechModel? = nil) {
        self.overriddenModelDirectory = modelDirectory
        self.urlSession = urlSession
        self.modelOverride = modelOverride
    }

    deinit {
        self.unloadModel()
    }

    var isReady: Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.ready
    }

    private var selectedModel: SettingsStore.SpeechModel {
        self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
    }

    private var modelName: String {
        self.selectedModel.whisperModelFile ?? "whisper-base-Q8_0.gguf"
    }

    private var legacyModelName: String? {
        self.selectedModel.legacyWhisperModelFile
    }

    private var modelURL: URL {
        self.modelDirectory.appendingPathComponent(self.modelName)
    }

    private var legacyModelURL: URL? {
        self.legacyModelName.map { self.modelDirectory.appendingPathComponent($0) }
    }

    private var modelDirectory: URL {
        if let overriddenModelDirectory {
            return overriddenModelDirectory
        }
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            preconditionFailure("Could not find caches directory")
        }
        return cacheDir.appendingPathComponent("WhisperModels")
    }

    private var modelDownloadURL: URL? {
        let modelName = self.modelName
        let suffix = "-Q8_0.gguf"
        guard modelName.hasSuffix(suffix) else { return nil }
        let repoName = String(modelName.dropLast(suffix.count))
        return URL(string: "https://huggingface.co/handy-computer/\(repoName)-gguf/resolve/main/\(modelName)")
    }

    private var backend: Backend {
        CPUArchitecture.isAppleSilicon ? .metal : .cpu
    }

    private func unloadModel() {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.session = nil
        self.model = nil
        self.ready = false
        self.loadedModelName = nil
    }

    private func currentLoadedModelName() -> String? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.loadedModelName
    }

    private func installModel(_ model: Model, session: Session, modelName: String) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.model = model
        self.session = session
        self.loadedModelName = modelName
        self.ready = true
    }

    private func activeSession() -> Session? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.session
    }

    private func removeLegacyModelIfNeeded() {
        for legacyFile in SettingsStore.SpeechModel.legacyWhisperModelFiles {
            let url = self.modelDirectory.appendingPathComponent(legacyFile)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                DebugLogger.shared.info("WhisperProvider: Removed legacy Whisper cache \(legacyFile)", source: "WhisperProvider")
            } catch {
                DebugLogger.shared.warning(
                    "WhisperProvider: Failed to remove legacy Whisper cache \(legacyFile): \(error.localizedDescription)",
                    source: "WhisperProvider"
                )
            }
        }
    }

    private func isModelFileValid(at url: URL, for targetModel: SettingsStore.SpeechModel) -> Bool {
        guard let expectedModelFile = targetModel.whisperModelFile,
              url.lastPathComponent == expectedModelFile
        else {
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value == targetModel.expectedDownloadBytes
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()

        let targetModel = self.selectedModel
        let currentModelName = targetModel.whisperModelFile ?? "whisper-base-Q8_0.gguf"

        let loadedModelName = self.currentLoadedModelName()
        if self.isReady, loadedModelName != currentModelName {
            DebugLogger.shared.info(
                "WhisperProvider: Model changed from \(loadedModelName ?? "nil") to \(currentModelName), forcing reload",
                source: "WhisperProvider"
            )
            self.unloadModel()
        }

        guard !self.isReady else { return }

        try Self.backendInitialization.get()
        try self.validateBackendAvailability(for: targetModel)

        try FileManager.default.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: self.modelURL.path),
           !self.isModelFileValid(at: self.modelURL, for: targetModel)
        {
            DebugLogger.shared.warning(
                "WhisperProvider: Found invalid model file at \(self.modelURL.path); removing to force re-download",
                source: "WhisperProvider"
            )
            try? FileManager.default.removeItem(at: self.modelURL)
        }

        if !FileManager.default.fileExists(atPath: self.modelURL.path) {
            DebugLogger.shared.info("WhisperProvider: Downloading Whisper GGUF model...", source: "WhisperProvider")
            progressHandler?(.preparingDownload)
            try await self.downloadModel { progress in
                progressHandler?(.downloading(progress))
            }
        }

        guard self.isModelFileValid(at: self.modelURL, for: targetModel) else {
            try? FileManager.default.removeItem(at: self.modelURL)
            throw NSError(
                domain: "WhisperProvider",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model file is missing or corrupted. Please re-download the model."]
            )
        }
        self.removeLegacyModelIfNeeded()

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

            Please try a smaller model or close other applications to free up memory.
            """
            DebugLogger.shared.error("WhisperProvider: \(errorMessage)", source: "WhisperProvider")
            throw NSError(
                domain: "WhisperProvider",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Loading \(currentModelName) with \(self.backend)", source: "WhisperProvider")
        progressHandler?(.loading)

        let loadedModel = try Model(
            path: self.modelURL.path,
            options: ModelOptions(backend: self.backend)
        )
        let runtimeBackend = loadedModel.backend.lowercased()
        if CPUArchitecture.isAppleSilicon,
           !runtimeBackend.contains("metal"),
           !runtimeBackend.contains("mtl")
        {
            throw NSError(
                domain: "WhisperProvider",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "\(targetModel.displayName) loaded on \(loadedModel.backend), but Metal is required on Apple Silicon."]
            )
        }
        let loadedSession = try loadedModel.session()

        try Task.checkCancellation()
        self.installModel(loadedModel, session: loadedSession, modelName: currentModelName)
        DebugLogger.shared.info(
            "WhisperProvider: Model ready (\(currentModelName), backend=\(loadedModel.backend), arch=\(loadedModel.arch))",
            source: "WhisperProvider"
        )
    }

    private func validateBackendAvailability(for model: SettingsStore.SpeechModel) throws {
        if CPUArchitecture.isAppleSilicon, !Transcribe.backendAvailable(.metal) {
            throw NSError(
                domain: "WhisperProvider",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "\(model.displayName) requires the Metal Whisper backend on Apple Silicon."]
            )
        }

        if !CPUArchitecture.isAppleSilicon, !Transcribe.backendAvailable(.cpu) {
            throw NSError(
                domain: "WhisperProvider",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Whisper CPU backend is unavailable on this Mac."]
            )
        }
    }

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
            DebugLogger.shared.warning("WhisperProvider: Failed to get memory stats, assuming sufficient memory", source: "WhisperProvider")
            return 16.0
        }

        let freePages = UInt64(vmStats.free_count)
        let inactivePages = UInt64(vmStats.inactive_count)
        let purgablePages = UInt64(vmStats.purgeable_count)
        let availableBytes = (freePages + inactivePages + purgablePages) * UInt64(pageSize)
        return Double(availableBytes) / (1024 * 1024 * 1024)
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples, languageCode: nil)
    }

    func transcribe(_ samples: [Float], languageCode: String?) async throws -> ASRTranscriptionResult {
        let minSamples = 16_000
        guard samples.count >= minSamples else {
            throw NSError(
                domain: "WhisperProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio too short for Whisper transcription"]
            )
        }

        guard let session = self.activeSession() else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded"]
            )
        }

        let transcript = try await session.run(
            samples,
            options: RunOptions(timestamps: .segment, language: languageCode)
        )
        let fullText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRTranscriptionResult(text: fullText, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        return self.isModelFileValid(at: self.modelURL, for: self.selectedModel)
    }

    func clearCache() async throws {
        self.unloadModel()

        if FileManager.default.fileExists(atPath: self.modelURL.path) {
            try FileManager.default.removeItem(at: self.modelURL)
        }
        if let legacyModelURL, FileManager.default.fileExists(atPath: legacyModelURL.path) {
            try FileManager.default.removeItem(at: legacyModelURL)
        }
        self.removeLegacyModelIfNeeded()

        if FileManager.default.fileExists(atPath: self.modelDirectory.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: self.modelDirectory.path)
            if contents.isEmpty {
                try FileManager.default.removeItem(at: self.modelDirectory)
            }
        }
    }

    private func downloadModel(progressHandler: ((Double) -> Void)?) async throws {
        guard let url = self.modelDownloadURL else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Whisper model URL"]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Downloading from \(url.absoluteString)", source: "WhisperProvider")

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
                if Task.isCancelled
                    || (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
                {
                    throw CancellationError()
                }

                let isLastAttempt = attempt == maxAttempts
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

                let delayNanos = UInt64(1_000_000_000) << UInt64(attempt - 1)
                try await Task.sleep(nanoseconds: delayNanos)
            }
        }
    }

    private func downloadFile(from url: URL, to destination: URL, progressHandler: ((Double) -> Void)?) async throws {
        var temporaryURL: URL?
        do {
            let (downloadedURL, response) = try await ProgressiveFileDownloader.download(
                from: url,
                configuration: self.urlSession.configuration
            ) { totalBytesWritten, totalBytesExpectedToWrite in
                guard totalBytesExpectedToWrite > 0 else { return }
                let pct = min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                progressHandler?(pct)
            }
            temporaryURL = downloadedURL
            try Task.checkCancellation()

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

            let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
            let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard actualBytes > 0 else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model is empty. Please try again."]
                )
            }
            if httpResponse.expectedContentLength > 0,
               actualBytes != httpResponse.expectedContentLength
            {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model size mismatch. Please try again."]
                )
            }

            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
            temporaryURL = nil
            try Task.checkCancellation()
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            let nsError = error as NSError
            if Task.isCancelled
                || error is CancellationError
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        progressHandler?(1.0)
    }
}
