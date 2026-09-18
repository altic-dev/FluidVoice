import AVFoundation
import CryptoKit
import Foundation

// Stage C2a observation boundary. The analysis manifest may only contain audio facts that were
// *actually observed*, so this is the single place that touches a chunk file: it confines the path
// to the session directory, refuses symlinks, re-verifies the recorded byte count and SHA-256, and
// then asks AVFoundation what the file really contains.
//
// Every failure is a typed value rather than an exception the caller might swallow. The builder
// converts each one into an explicit analysis gap, so unreadable audio becomes visible missing
// coverage instead of silence that looks like it was transcribed.

/// Why one chunk could not become analysable audio. Each maps to exactly one gap reason.
nonisolated enum MeetingChunkObservationFailure: String, Codable, Equatable, CaseIterable {
    case fileMissing
    /// The path escaped the session directory, or a component of it was a symlink.
    case pathRejected
    case byteCountChanged
    case hashChanged
    /// The file exists and verifies, but no decoder would open it.
    case unreadable
    /// Zero bytes on disk, or zero decoded frames.
    case emptyAudio
    /// The decoder reported a non-positive sample rate, so no duration follows from its frames.
    case sampleRateUnusable
    /// A PCM-first chunk advertised an authoritative capture asset that was incomplete or
    /// internally inconsistent. The legacy AAC path is never used as a substitute.
    case analysisAssetInvalid

    var gapReason: MeetingAnalysisGapReason {
        switch self {
        case .fileMissing: return .chunkFileMissing
        case .pathRejected: return .chunkPathRejected
        case .byteCountChanged: return .chunkByteCountChanged
        case .hashChanged: return .chunkHashChanged
        case .unreadable: return .chunkUnreadable
        case .emptyAudio: return .chunkEmpty
        case .sampleRateUnusable: return .chunkSampleRateUnusable
        case .analysisAssetInvalid: return .chunkAnalysisAssetInvalid
        }
    }
}

nonisolated enum MeetingChunkObservationResult: Equatable {
    case observed(MeetingChunkObservedAudio)
    case failed(MeetingChunkObservationFailure, detail: String?)
}

/// The manifest builder's only route to the filesystem. Injectable so the builder can be exercised
/// over synthetic topologies without writing audio, and so the production reader stays one small,
/// auditable implementation.
nonisolated protocol MeetingChunkAudioObserving: Sendable {
    func observe(chunk: MeetingAudioChunk, trackID: MeetingAudioTrackID) -> MeetingChunkObservationResult
}

nonisolated struct MeetingChunkAudioObserver: MeetingChunkAudioObserving {
    let sessionDirectory: URL

    func observe(chunk: MeetingAudioChunk, trackID _: MeetingAudioTrackID) -> MeetingChunkObservationResult {
        let authority: (path: String, byteCount: Int64, sha256: String, asset: MeetingAudioAsset?)
        if chunk.audioSchemaVersion != nil {
            guard let asset = chunk.captureAnalysisAsset,
                  asset.presence == .ready,
                  asset.role == .captureAnalysis,
                  asset.encoding == .linearPCMFloat32CAFV1,
                  asset.validationIssues().isEmpty,
                  let hash = asset.sha256, !hash.isEmpty
            else {
                return .failed(.analysisAssetInvalid, detail: "A PCM-first chunk has no valid ready linear-PCM capture asset.")
            }
            authority = (asset.relativeFilePath, asset.byteCount, hash, asset)
        } else {
            guard chunk.byteCount > 0, !chunk.sha256.isEmpty else {
                return .failed(.emptyAudio, detail: "The session manifest records no bytes for this chunk.")
            }
            authority = (chunk.relativeFilePath, chunk.byteCount, chunk.sha256, nil)
        }
        guard authority.byteCount > 0, !authority.sha256.isEmpty else {
            return .failed(.emptyAudio, detail: "The session manifest records no bytes for this chunk.")
        }
        let url: URL
        do {
            url = try self.containedURL(relativePath: authority.path)
        } catch {
            return .failed(.pathRejected, detail: authority.path)
        }

        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            return .failed(.fileMissing, detail: authority.path)
        }
        let actualByteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualByteCount >= 0 else {
            return .failed(.fileMissing, detail: authority.path)
        }
        guard actualByteCount > 0 else {
            return .failed(.emptyAudio, detail: "0 bytes on disk.")
        }
        guard actualByteCount == authority.byteCount else {
            return .failed(
                .byteCountChanged,
                detail: "Expected \(authority.byteCount) bytes, found \(actualByteCount)."
            )
        }

        guard let digest = Self.sha256Hex(contentsOf: url) else {
            return .failed(.unreadable, detail: "The chunk could not be read for hashing.")
        }
        guard digest == authority.sha256.lowercased() else {
            return .failed(.hashChanged, detail: "Recorded digest no longer matches the file.")
        }

        return Self.decodedFacts(at: url, byteCount: actualByteCount, sha256: digest, asset: authority.asset)
    }

    /// What a decoder actually reports. Codec priming stays `unknown(.decoderDidNotReport)`:
    /// `AVAudioFile` exposes a decoded frame count, not an encoder delay, and this build has no
    /// verified way to tell whether that frame count already excludes the priming frames. Guessing
    /// either way would either double-trim real speech or shift every word by a delay nobody
    /// measured, which is exactly the universal-AAC-delay assumption the plan forbids.
    private static func decodedFacts(
        at url: URL,
        byteCount: Int64,
        sha256: String,
        asset: MeetingAudioAsset? = nil
    ) -> MeetingChunkObservationResult {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return .failed(.unreadable, detail: error.localizedDescription)
        }
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0 else {
            return .failed(.sampleRateUnusable, detail: "Decoder reported sample rate \(format.sampleRate).")
        }
        guard format.channelCount > 0 else {
            return .failed(.unreadable, detail: "Decoder reported \(format.channelCount) channels.")
        }
        let frameCount = Int64(file.length)
        guard frameCount > 0 else {
            return .failed(.emptyAudio, detail: "Decoder reported 0 frames.")
        }
        if let asset {
            guard asset.encoding == .linearPCMFloat32CAFV1,
                  format.commonFormat == .pcmFormatFloat32,
                  format.sampleRate == asset.sampleRate,
                  Int(format.channelCount) == asset.channelCount,
                  frameCount == asset.frameCount
            else {
                return .failed(.analysisAssetInvalid, detail: "PCM capture asset metadata does not match its CAF contents.")
            }
        }
        return .observed(MeetingChunkObservedAudio(
            byteCount: byteCount,
            sha256: sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                frameCount: frameCount,
                durationSeconds: Double(frameCount) / format.sampleRate,
                codecPriming: asset == nil
                    ? .unknown(.decoderDidNotReport)
                    : .notApplicable(.linearPCMFloat32CAFV1),
                processingFormatDescription: "sampleRate=\(format.sampleRate);channels=\(format.channelCount);"
                    + "commonFormat=\(format.commonFormat.rawValue);interleaved=\(format.isInterleaved)"
            )
        ))
    }

    /// Canonicalize the session root once, then require every component the chunk adds to be a
    /// real, non-symlink component underneath it. A pre-existing symlink inside the session
    /// directory is rejected as firmly as one that escapes it: both would make the verified digest
    /// describe a different file than the one a decoder later opens.
    private func containedURL(relativePath: String) throws -> URL {
        try MeetingChunkPathConfinement.containedURL(
            sessionDirectory: self.sessionDirectory,
            relativePath: relativePath
        )
    }

    private static func sha256Hex(contentsOf url: URL) -> String? {
        MeetingChunkPathConfinement.sha256Hex(contentsOf: url)
    }
}

/// The confinement and hashing primitives shared by the chunk observer and the Stage E epoch
/// materializer. Both must agree exactly: a path either is a real, non-symlink file inside the
/// session directory or it is rejected, and the digest is computed the same way in both places.
nonisolated enum MeetingChunkPathConfinement {
    struct PathRejected: Error {}

    static func containedURL(sessionDirectory: URL, relativePath: String) throws -> URL {
        let root = sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(".."),
              !components.contains(".")
        else { throw PathRejected() }

        let manager = FileManager.default
        var current = root
        for component in components {
            current.appendPathComponent(component, isDirectory: false)
            if let attributes = try? manager.attributesOfItem(atPath: current.path),
               (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            {
                throw PathRejected()
            }
        }
        let candidate = current.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { throw PathRejected() }
        return candidate
    }

    static func sha256Hex(contentsOf url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            do {
                guard let block = try handle.read(upToCount: 1 << 20), !block.isEmpty else { break }
                hasher.update(data: block)
            } catch {
                return nil
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
