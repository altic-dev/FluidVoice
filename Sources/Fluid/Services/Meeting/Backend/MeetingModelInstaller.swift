import CryptoKit
import Darwin
import Foundation

/// Installs the Nemotron 3 Diarization package. Checksums identify the exact published package
/// (fp16 weight storage, fp32 compute), not an arbitrary CoreML model with a matching filename.
/// Run off the main actor.
nonisolated enum MeetingModelInstaller {
    private static let installationLock = NSLock()
    private static let expectedFiles = [
        "Manifest.json": "87c6d992c3300934d6b0205dbcf0a34df93e4b5716e6ccd1de846147b2937705",
        "Data/com.apple.CoreML/model.mlmodel": "3da7a6f70a632e9079116f9c14bf7afbf5ff69ac5b28e90dd4277a9ce41f8642",
        "Data/com.apple.CoreML/weights/weight.bin": "b7c50bd483210f206014548c0cc2fc7b3601de012ab86b2e49f8a911db9a7d40",
    ]

    /// The checkpoint's trained silence embedding (`learnable_sil_emb`), published next to the
    /// package: 512 little-endian float32 values.
    static let silenceEmbeddingFileName = "learnable_sil_emb.f32"
    private static let silenceEmbeddingSHA256 = "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"
    private static let silenceEmbeddingDimensions = 512

    enum InstallError: LocalizedError {
        case wrongPackage
        var errorDescription: String? {
            "The downloaded speaker model is different or damaged. Try the download again."
        }
    }

    static func validate(_ package: URL) throws -> MeetingNemotronModelArtifact {
        let artifact = try MeetingNemotronModelLocator.validatePackage(at: package.standardizedFileURL)
        for (path, expected) in Self.expectedFiles {
            let handle = try FileHandle(forReadingFrom: package.appendingPathComponent(path))
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw InstallError.wrongPackage
            }
        }
        return artifact
    }

    static func silenceEmbeddingURL(besides package: URL) -> URL {
        package.deletingLastPathComponent().appendingPathComponent(self.silenceEmbeddingFileName)
    }

    /// Reads the silence embedding only when its bytes are exactly the published file.
    static func validatedSilenceEmbedding(at url: URL) throws -> [Float] {
        guard let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.silenceEmbeddingSHA256,
              data.count == Self.silenceEmbeddingDimensions * MemoryLayout<UInt32>.size
        else {
            throw InstallError.wrongPackage
        }
        return stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map { offset in
            Float(bitPattern: UInt32(littleEndian: data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        }
    }

    static func installSilenceEmbedding(from source: URL, besides package: URL) throws {
        _ = try self.validatedSilenceEmbedding(at: source)
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.silenceEmbeddingURL(besides: package), options: .atomic)
    }

    static func install(from source: URL, to destination: URL = MeetingNemotronModelLocator.defaultPackageURL()) throws -> MeetingNemotronModelArtifact {
        self.installationLock.lock()
        defer { self.installationLock.unlock() }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        _ = try Self.validate(source)
        if source.standardizedFileURL == destination.standardizedFileURL {
            return try Self.validate(destination)
        }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("import-\(UUID().uuidString).mlpackage", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        let artifact = try Self.validate(staging)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            // Atomically swap directory packages; staging then contains the old model.
            let result = staging.withUnsafeFileSystemRepresentation { stagedPath in
                destination.withUnsafeFileSystemRepresentation { destinationPath in
                    renameatx_np(AT_FDCWD, stagedPath, AT_FDCWD, destinationPath, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        return MeetingNemotronModelArtifact(
            packageURL: destination,
            totalByteCount: artifact.totalByteCount,
            fileCount: artifact.fileCount,
            manifestSHA256: artifact.manifestSHA256,
            entryMetadataSHA256: artifact.entryMetadataSHA256
        )
    }
}
