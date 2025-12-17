import CoreML
import Foundation
#if arch(arm64)
import FluidAudio
#endif

/// A robust downloader for Hugging Face models with progress tracking and error handling.
/// Supports downloading entire model repositories with proper file structure preservation.
/// Can be configured to use different model repositories for flexibility.
final class HuggingFaceModelDownloader {
    struct HFEntry: Decodable {
        let type: String
        let path: String
    }

    struct ModelItem {
        let path: String
        let isDirectory: Bool
    }

    // Configure your optimized repository here
    // These can be customized for different model repositories
    private let owner: String
    private let repo: String
    private let revision: String

    private var baseApiURL: URL
    private var baseResolveURL: URL

    /// Initialize with default model repository settings
    init() {
        self.owner = "FluidInference"
        self.repo = "parakeet-tdt-0.6b-v3-coreml"
        self.revision = "main"
        guard var apiBase = URL(string: "https://huggingface.co/api/models/") else {
            preconditionFailure("Invalid base Hugging Face API URL")
        }
        apiBase.appendPathComponent(self.owner)
        apiBase.appendPathComponent(self.repo)
        apiBase.appendPathComponent("tree")
        apiBase.appendPathComponent(self.revision)
        self.baseApiURL = apiBase

        guard var resolveBase = URL(string: "https://huggingface.co/") else {
            preconditionFailure("Invalid base Hugging Face resolve URL")
        }
        resolveBase.appendPathComponent(self.owner)
        resolveBase.appendPathComponent(self.repo)
        resolveBase.appendPathComponent("resolve")
        resolveBase.appendPathComponent(self.revision)
        self.baseResolveURL = resolveBase
    }

    /// Initialize with custom model repository settings
    /// - Parameters:
    ///   - owner: Hugging Face username or organization
    ///   - repo: Repository name containing the models
    ///   - revision: Branch or commit hash (default: "main")
    init(owner: String, repo: String, revision: String = "main") {
        self.owner = owner
        self.repo = repo
        self.revision = revision
        guard var apiBase = URL(string: "https://huggingface.co/api/models/") else {
            preconditionFailure("Invalid base Hugging Face API URL")
        }
        apiBase.appendPathComponent(owner)
        apiBase.appendPathComponent(repo)
        apiBase.appendPathComponent("tree")
        apiBase.appendPathComponent(revision)
        self.baseApiURL = apiBase

        guard var resolveBase = URL(string: "https://huggingface.co/") else {
            preconditionFailure("Invalid base Hugging Face resolve URL")
        }
        resolveBase.appendPathComponent(owner)
        resolveBase.appendPathComponent(repo)
        resolveBase.appendPathComponent("resolve")
        resolveBase.appendPathComponent(revision)
        self.baseResolveURL = resolveBase
    }

    func ensureModelsPresent(at targetRoot: URL, onProgress: ((Double, String) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        // Build list of files to download (flatten directories via HF API tree)
        var pendingFiles: [String] = []
        for item in self.requiredItems() {
            if item.isDirectory {
                let files = try await listFilesRecursively(relativePath: item.path)
                for rel in files {
                    let dest = targetRoot.appendingPathComponent(rel)
                    if FileManager.default.fileExists(atPath: dest.path) == false {
                        pendingFiles.append(rel)
                    }
                }
            } else {
                let dest = targetRoot.appendingPathComponent(item.path)
                if FileManager.default.fileExists(atPath: dest.path) == false {
                    pendingFiles.append(item.path)
                }
            }
        }

        // If nothing to download, say so clearly
        if pendingFiles.isEmpty {
            print("[ModelDL] All required model files are already present. Nothing to download.")
            onProgress?(1.0, "")
            return
        }

        // Compute total bytes (best-effort) for determinate progress
        var sizeByPath: [String: Int64] = [:]
        var totalBytes: Int64 = 0
        for rel in pendingFiles {
            let expected = try await headExpectedLength(relativePath: rel)
            sizeByPath[rel] = expected
            if expected > 0 { totalBytes += expected }
        }

        let totalHuman = Self.formatBytes(totalBytes)
        print("[ModelDL] Files to download: \(pendingFiles.count), total size: \(totalHuman)")

        var downloadedBytes: Int64 = 0
        let fallbackTotal = pendingFiles.count
        var fallbackCompleted = 0

        for (idx, rel) in pendingFiles.enumerated() {
            print("[ModelDL] (\(idx + 1)/\(pendingFiles.count)) Downloading: \(rel)")
            try await self.downloadFile(relativePath: rel, to: targetRoot.appendingPathComponent(rel)) { perFilePct in
                if totalBytes > 0 {
                    let expected = sizeByPath[rel] ?? 0
                    if expected > 0 {
                        let overallBase = Double(downloadedBytes) / Double(totalBytes)
                        let combined = min(1.0, overallBase + (perFilePct * Double(expected)) / Double(totalBytes))
                        onProgress?(combined, rel)
                        print(String(format: "[ModelDL] File progress: %.1f%% (%@)", perFilePct * 100.0, rel))
                        print(String(format: "[ModelDL] Overall progress (est.): %.1f%%", combined * 100.0))
                    }
                }
            }
            if totalBytes > 0 {
                downloadedBytes += (sizeByPath[rel] ?? 0)
                let pct = min(1.0, Double(downloadedBytes) / Double(totalBytes))
                onProgress?(pct, rel)
                print(String(
                    format: "[ModelDL] Overall progress: %.1f%% (\(Self.formatBytes(downloadedBytes))/\(Self.formatBytes(totalBytes)))",
                    pct * 100.0
                ))
            } else if fallbackTotal > 0 {
                fallbackCompleted += 1
                onProgress?(Double(fallbackCompleted) / Double(fallbackTotal), rel)
                print("[ModelDL] Overall progress: \(fallbackCompleted)/\(fallbackTotal)")
            }
        }
    }

    private func requiredItems() -> [ModelItem] {
        return [
            // Preferred v3 unified model file names used by FluidAudio 0.5+
            ModelItem(path: "MelEncoder.mlmodelc", isDirectory: true),
            ModelItem(path: "Decoder.mlmodelc", isDirectory: true),
            ModelItem(path: "JointDecision.mlmodelc", isDirectory: true),
            ModelItem(path: "parakeet_v3_vocab.json", isDirectory: false),
        ]
    }

    private func downloadDirectory(relativePath: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Download entire directory by enumerating all files
        let files = try await listFilesRecursively(relativePath: relativePath)
        for rel in files {
            let dest = destination.deletingLastPathComponent().appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await self.downloadFile(relativePath: rel, to: dest)
        }
    }

    private func downloadFile(
        relativePath: String,
        to destination: URL,
        perFileProgress: ((Double) -> Void)? = nil
    ) async throws {
        let fileURL = self.baseResolveURL.appendingPathComponent(relativePath)

        let delegate = DownloadProgressDelegate(onProgress: perFileProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: fileURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.onFinish = { tempUrl, response in
                do {
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        continuation.resume(throwing: NSError(domain: "HF", code: http.statusCode))
                        return
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempUrl, to: destination)
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
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        private let onProgress: ((Double) -> Void)?
        var onFinish: ((URL, URLResponse) -> Void)?
        var onError: ((Error) -> Void)?

        init(onProgress: ((Double) -> Void)?) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
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

    private func headExpectedLength(relativePath: String) async throws -> Int64 {
        let fileURL = self.baseResolveURL.appendingPathComponent(relativePath)
        var req = URLRequest(url: fileURL)
        req.httpMethod = "HEAD"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            return 0
        }
        return http.expectedContentLength
    }

    private func listFilesRecursively(relativePath: String) async throws -> [String] {
        let listingURL = self.baseApiURL
            .appendingPathComponent(relativePath)
        guard var comps = URLComponents(url: listingURL, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid listing URL components"])
        }
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]

        guard let url = comps.url else {
            throw NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid listing URL"])
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "HF", code: http.statusCode)
        }

        let decoder = JSONDecoder()
        let entries = try decoder.decode([HFEntry].self, from: data)

        return entries
            .filter { $0.type == "file" }
            .map { $0.path }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let b = Double(bytes)
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.2f KB", b / kb) }
        return "\(bytes) B"
    }
}

#if arch(arm64)
extension HuggingFaceModelDownloader {
    /// Load ASR models directly from disk using unified v3 model names
    func loadLocalAsrModels(from repoDirectory: URL) async throws -> AsrModels {
        let config = AsrModels.defaultConfiguration()
        let fm = FileManager.default

        // Try to load with new naming convention first (Preprocessor + Encoder)
        let preprocessorUrl = repoDirectory.appendingPathComponent("Preprocessor.mlmodelc")
        let encoderUrl = repoDirectory.appendingPathComponent("Encoder.mlmodelc")
        let decUrl = repoDirectory.appendingPathComponent("Decoder.mlmodelc")
        let jointUrl = repoDirectory.appendingPathComponent("JointDecision.mlmodelc")

        print("[ModelDL] Loading v3 models from: \(repoDirectory.path)")
        print("[ModelDL] Preprocessor path: \(preprocessorUrl.path)")
        print("[ModelDL] Encoder path: \(encoderUrl.path)")
        print("[ModelDL] Decoder path: \(decUrl.path)")
        print("[ModelDL] JointDecision path: \(jointUrl.path)")

        // Check if new structure exists
        let hasNewStructure = fm.fileExists(atPath: preprocessorUrl.path) && fm.fileExists(atPath: encoderUrl.path)

        let encoder: MLModel
        let preprocessor: MLModel?

        if hasNewStructure {
            // Load with new structure (separate Preprocessor and Encoder)
            print("[ModelDL] Loading with new model structure (Preprocessor + Encoder)")
            preprocessor = try MLModel(contentsOf: preprocessorUrl, configuration: config)
            encoder = try MLModel(contentsOf: encoderUrl, configuration: config)
        } else {
            // Fallback: Try old structure (MelEncoder)
            let melEncUrl = repoDirectory.appendingPathComponent("MelEncoder.mlmodelc")
            print("[ModelDL] New structure not found, trying legacy MelEncoder")
            print("[ModelDL] MelEncoder path: \(melEncUrl.path)")
            print("[ModelDL] MelEncoder exists: \(fm.fileExists(atPath: melEncUrl.path))")

            if fm.fileExists(atPath: melEncUrl.path) {
                encoder = try MLModel(contentsOf: melEncUrl, configuration: config)
                preprocessor = nil
                print("[ModelDL] Using MelEncoder (legacy mode)")
            } else {
                throw NSError(domain: "ModelDL", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Neither new model structure (Preprocessor + Encoder) nor legacy structure (MelEncoder) found",
                ])
            }
        }

        // Load decoder and joint (same for both structures)
        let decoder = try MLModel(contentsOf: decUrl, configuration: config)
        let joint = try MLModel(contentsOf: jointUrl, configuration: config)

        // Load vocabulary (JSON: {"0": "<pad>", ...}) from repo root
        let vocabPath = repoDirectory.deletingLastPathComponent().appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
            .appendingPathComponent("parakeet_v3_vocab.json")
        guard fm.fileExists(atPath: vocabPath.path) else {
            throw NSError(
                domain: "ModelDL",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Vocabulary file not found at \(vocabPath.path)"]
            )
        }
        let vocabData = try Data(contentsOf: vocabPath)
        let raw = try JSONSerialization.jsonObject(with: vocabData) as? [String: String] ?? [:]
        var vocabulary: [Int: String] = [:]
        vocabulary.reserveCapacity(raw.count)
        for (k, v) in raw {
            if let idx = Int(k) { vocabulary[idx] = v }
        }

        print("[ModelDL] Creating AsrModels")

        // For v2 models without separate preprocessor, use encoder as preprocessor
        // For v3 models, use the separate preprocessor
        let finalPreprocessor = preprocessor ?? encoder

        return AsrModels(
            encoder: encoder,
            preprocessor: finalPreprocessor,
            decoder: decoder,
            joint: joint,
            configuration: config,
            vocabulary: vocabulary,
            version: preprocessor != nil ? .v3 : .v2
        )
    }
}
#endif
