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
    private let requiredItemsList: [ModelItem]

    private var baseApiURL: URL
    private var baseResolveURL: URL

    /// Initialize with default model repository settings
    init() {
        self.owner = "FluidInference"
        self.repo = "parakeet-tdt-0.6b-v3-coreml"
        self.revision = "main"
        self.requiredItemsList = [
            ModelItem(path: "MelEncoder.mlmodelc", isDirectory: true),
            ModelItem(path: "Decoder.mlmodelc", isDirectory: true),
            ModelItem(path: "JointDecision.mlmodelc", isDirectory: true),
            ModelItem(path: "parakeet_v3_vocab.json", isDirectory: false),
        ]
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
    init(owner: String, repo: String, revision: String = "main", requiredItems: [ModelItem] = []) {
        self.owner = owner
        self.repo = repo
        self.revision = revision
        self.requiredItemsList = requiredItems.isEmpty
            ? [
                ModelItem(path: "MelEncoder.mlmodelc", isDirectory: true),
                ModelItem(path: "Decoder.mlmodelc", isDirectory: true),
                ModelItem(path: "JointDecision.mlmodelc", isDirectory: true),
                ModelItem(path: "parakeet_v3_vocab.json", isDirectory: false),
            ]
            : requiredItems
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
                    if self.needsDownload(relativePath: rel, at: dest) {
                        pendingFiles.append(rel)
                    }
                }
            } else {
                let dest = targetRoot.appendingPathComponent(item.path)
                if self.needsDownload(relativePath: item.path, at: dest) {
                    pendingFiles.append(item.path)
                }
            }
        }

        // If nothing to download, say so clearly
        if pendingFiles.isEmpty {
            DebugLogger.shared.info("[ModelDL] All required model files are already present. Nothing to download.", source: "ModelDownloader")
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
        DebugLogger.shared.info("[ModelDL] Files to download: \(pendingFiles.count), total size: \(totalHuman)", source: "ModelDownloader")

        var downloadedBytes: Int64 = 0
        let fallbackTotal = pendingFiles.count
        var fallbackCompleted = 0

        for (idx, rel) in pendingFiles.enumerated() {
            DebugLogger.shared.info("[ModelDL] (\(idx + 1)/\(pendingFiles.count)) Downloading: \(rel)", source: "ModelDownloader")
            try await self.downloadFile(relativePath: rel, to: targetRoot.appendingPathComponent(rel)) { perFilePct in
                if totalBytes > 0 {
                    let expected = sizeByPath[rel] ?? 0
                    if expected > 0 {
                        let overallBase = Double(downloadedBytes) / Double(totalBytes)
                        let combined = min(1.0, overallBase + (perFilePct * Double(expected)) / Double(totalBytes))
                        onProgress?(combined, rel)
                        DebugLogger.shared.debug(String(format: "[ModelDL] File progress: %.1f%% (%@)", perFilePct * 100.0, rel), source: "ModelDownloader")
                        DebugLogger.shared.debug(String(format: "[ModelDL] Overall progress (est.): %.1f%%", combined * 100.0), source: "ModelDownloader")
                    }
                }
            }
            if totalBytes > 0 {
                downloadedBytes += (sizeByPath[rel] ?? 0)
                let pct = min(1.0, Double(downloadedBytes) / Double(totalBytes))
                onProgress?(pct, rel)
                DebugLogger.shared.info(String(format: "[ModelDL] Overall progress: %.1f%% (\(Self.formatBytes(downloadedBytes))/\(Self.formatBytes(totalBytes)))", pct * 100.0), source: "ModelDownloader")
            } else if fallbackTotal > 0 {
                fallbackCompleted += 1
                onProgress?(Double(fallbackCompleted) / Double(fallbackTotal), rel)
                DebugLogger.shared.info("[ModelDL] Overall progress: \(fallbackCompleted)/\(fallbackTotal)", source: "ModelDownloader")
            }
        }
    }

    private func requiredItems() -> [ModelItem] {
        self.requiredItemsList
    }

    /// Decides whether `relativePath` needs to be (re)downloaded into `destination`.
    ///
    /// A file is pending when it is missing, OR when it is present but its cached content
    /// looks like an HTML/markup payload — a corrupt artifact cached before download-time
    /// content validation existed (see #353). `fileExists` alone would leave such a payload
    /// stuck forever, because `downloadFile` (and its validator) only runs for pending files.
    /// A present markup file is deleted here so a clean copy is fetched; on a read error the
    /// file is left in place and treated as valid, so we never delete on uncertainty.
    private func needsDownload(relativePath: String, at destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return true
        }
        guard Self.cachedFileIsMarkup(at: destination) else {
            return false
        }
        DebugLogger.shared.warning(
            "[ModelDL] Cached file is an HTML/markup page, not model data; deleting to re-download: \(relativePath)",
            source: "ModelDownloader"
        )
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            DebugLogger.shared.error(
                "[ModelDL] Failed to delete corrupt cached file \(relativePath): \(error.localizedDescription)",
                source: "ModelDownloader"
            )
        }
        return true
    }

    private func downloadDirectory(relativePath: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Download entire directory by enumerating all files
        let files = try await listFilesRecursively(relativePath: relativePath)
        for rel in files {
            let dest = destination.deletingLastPathComponent().appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await self.downloadFile(relativePath: rel, to: dest)
        }
    }

    private func downloadFile(relativePath: String, to destination: URL, perFileProgress: ((Double) -> Void)? = nil) async throws {
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
                    // Reject HTML error/block pages (e.g. a corporate proxy returning its
                    // notification page with HTTP 200) before persisting them as a model
                    // file, otherwise a corrupt payload is cached permanently. See #353.
                    try Self.validateDownloadedFile(at: tempUrl, response: response, relativePath: relativePath)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempUrl, to: destination)
                    continuation.resume()
                } catch {
                    // Never leave a rejected/partial payload behind.
                    try? FileManager.default.removeItem(at: tempUrl)
                    continuation.resume(throwing: error)
                }
            }
            delegate.onError = { error in
                continuation.resume(throwing: error)
            }
            task.resume()
        }
    }

    // MARK: - Content Validation

    /// Validates a freshly-downloaded artifact before it is persisted as a model file.
    ///
    /// A network proxy / secure web gateway can return an HTML (or XML) block page with
    /// HTTP 200 in place of the real file. Persisting that markup (e.g. as `coremldata.bin`)
    /// permanently caches a corrupt model. We reject any payload that looks like HTML/XML
    /// markup — by its `Content-Type` or by its leading bytes — since no model artifact
    /// (CoreML binary, JSON vocab, `.mil`) is a markup document. See issue #353.
    static func validateDownloadedFile(at fileURL: URL, response: URLResponse?, relativePath: String) throws {
        if let http = response as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type") {
            let lowered = contentType.lowercased()
            if lowered.contains("text/html") || lowered.contains("text/xml") || lowered.contains("application/xml") {
                throw Self.invalidContentError(
                    relativePath: relativePath,
                    detail: "the server returned a markup page (Content-Type: \(contentType))"
                )
            }
        }

        // Sniff the leading bytes in case markup was returned without a markup Content-Type.
        // Read a small prefix only — model files can be gigabytes.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 512)) ?? Data()
        if Self.looksLikeHTML(prefix) {
            throw Self.invalidContentError(
                relativePath: relativePath,
                detail: "the downloaded file is an HTML/markup document, not the expected model data"
            )
        }
    }

    /// Returns `true` if a file already on disk is an HTML/markup payload rather than real
    /// model data — a corrupt artifact cached before download-time validation existed (#353).
    ///
    /// This is the cached-file analog of `validateDownloadedFile`'s byte-sniff: it reuses the
    /// same `looksLikeHTML` check on a small leading prefix (model files can be gigabytes, so
    /// only 512 bytes are read). There is no `URLResponse` for a cached file, so only the
    /// content is inspected, not a `Content-Type`. Returns `false` (treat as valid) on any
    /// read error, so an unreadable file is never deleted on uncertainty.
    static func cachedFileIsMarkup(at fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 512)) ?? Data()
        return Self.looksLikeHTML(prefix)
    }

    /// Returns `true` if any cached payload under `relativePaths` (each resolved against `root`)
    /// is an HTML/markup document rather than real model data — the cached-*tree* analog of
    /// `cachedFileIsMarkup`, intended for a provider preflight to call before trusting a present
    /// cache and skipping the downloader. The downloader itself already re-validates each file via
    /// `needsDownload`, but a preflight that returns on file-existence alone never reaches it, so a
    /// corrupt-but-present cache would slip through (see #353).
    ///
    /// Each relative path may be a regular file or a directory (e.g. a `.mlpackage` bundle).
    /// Directories are scanned recursively and every regular file inside is byte-sniffed with
    /// `cachedFileIsMarkup`, reusing the single `looksLikeHTML` detector — there is no second
    /// markup heuristic. Conservative on uncertainty, mirroring `cachedFileIsMarkup`: a path that
    /// does not exist, a file that cannot be read, or a directory that cannot be enumerated is
    /// skipped (treated as non-markup), so a valid cache is never reported corrupt. An empty
    /// required directory therefore yields `false` here — its incompleteness is the existence
    /// check's concern, not this markup check's.
    static func cachedPayloadContainsMarkup(root: URL, relativePaths: [String]) -> Bool {
        let fileManager = FileManager.default
        for relativePath in relativePaths {
            let url = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                for case let fileURL as URL in enumerator {
                    let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                    guard isRegularFile else { continue }
                    if Self.cachedFileIsMarkup(at: fileURL) {
                        return true
                    }
                }
            } else if Self.cachedFileIsMarkup(at: url) {
                return true
            }
        }
        return false
    }

    /// Returns `true` if `data` begins with an HTML / XML markup marker, ignoring a leading
    /// UTF-8 BOM and ASCII whitespace.
    ///
    /// No artifact this downloader fetches legitimately begins with `<`: CoreML compiled
    /// `.mlmodelc` / `.mlpackage` payloads are binary (`coremldata.bin`, `weights/weight.bin`,
    /// `model.mlmodel` protobuf) or JSON (`metadata.json`, `Manifest.json`) starting with
    /// `{` / `[`; the MIL program text (`model.mil`) starts with `program`; the vocab JSON
    /// starts with `{`; and `tokenizer.model` is a SentencePiece binary. So any payload that,
    /// after BOM + whitespace stripping, starts with `<` followed by a markup-ish byte is a
    /// proxy/block page or a markup document standing in for the real file — reject it. This
    /// catches `<!doctype`, `<html`, `<head>`, `<body>`, `<script>`, `<meta>`, comments
    /// (`<!-- -->`) and XML / `<?xml` declarations, not just the two prefixes we used to
    /// match. See issue #353.
    static func looksLikeHTML(_ data: Data) -> Bool {
        var bytes = [UInt8](data.prefix(512))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        while let first = bytes.first,
              first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            bytes.removeFirst()
        }
        // Must begin with `<` (0x3C)…
        guard bytes.first == 0x3C, bytes.count >= 2 else {
            return false
        }
        // …immediately followed by a markup-ish byte: an ASCII letter (a tag such as
        // `<html`), `!` (0x21 — `<!doctype`, `<!--`), `?` (0x3F — `<?xml`), or `/` (0x2F —
        // a stray closing tag). Requiring this second byte avoids over-rejecting a
        // hypothetical text artifact that merely contains a stray `<` not followed by markup.
        let second = bytes[1]
        let isAsciiLetter = (second >= 0x41 && second <= 0x5A) || (second >= 0x61 && second <= 0x7A)
        return isAsciiLetter || second == 0x21 || second == 0x3F || second == 0x2F
    }

    private static func invalidContentError(relativePath: String, detail: String) -> NSError {
        NSError(domain: "HF", code: -3, userInfo: [
            NSLocalizedDescriptionKey:
                "Could not download \(relativePath): \(detail). A network proxy or firewall may be blocking model downloads.",
        ])
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

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
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

        DebugLogger.shared.info("[ModelDL] Loading v3 models from: \(repoDirectory.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] Preprocessor path: \(preprocessorUrl.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] Encoder path: \(encoderUrl.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] Decoder path: \(decUrl.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] JointDecision path: \(jointUrl.path)", source: "ModelDownloader")

        // Check if new structure exists
        let hasNewStructure = fm.fileExists(atPath: preprocessorUrl.path) && fm.fileExists(atPath: encoderUrl.path)

        let encoder: MLModel
        let preprocessor: MLModel?

        if hasNewStructure {
            // Load with new structure (separate Preprocessor and Encoder)
            DebugLogger.shared.info("[ModelDL] Loading with new model structure (Preprocessor + Encoder)", source: "ModelDownloader")
            preprocessor = try MLModel(contentsOf: preprocessorUrl, configuration: config)
            encoder = try MLModel(contentsOf: encoderUrl, configuration: config)
        } else {
            // Fallback: Try old structure (MelEncoder)
            let melEncUrl = repoDirectory.appendingPathComponent("MelEncoder.mlmodelc")
            DebugLogger.shared.info("[ModelDL] New structure not found, trying legacy MelEncoder", source: "ModelDownloader")
            DebugLogger.shared.debug("[ModelDL] MelEncoder path: \(melEncUrl.path)", source: "ModelDownloader")
            DebugLogger.shared.debug("[ModelDL] MelEncoder exists: \(fm.fileExists(atPath: melEncUrl.path))", source: "ModelDownloader")

            if fm.fileExists(atPath: melEncUrl.path) {
                encoder = try MLModel(contentsOf: melEncUrl, configuration: config)
                preprocessor = nil
                DebugLogger.shared.info("[ModelDL] Using MelEncoder (legacy mode)", source: "ModelDownloader")
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

        DebugLogger.shared.debug("[ModelDL] Creating AsrModels", source: "ModelDownloader")

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
