import Foundation

/// Resolves the audio representation used by meeting history actions.
///
/// PCM is the authoritative representation during processing. Once a verified archive exists,
/// history actions prefer it; otherwise they use the finalized PCM path recorded on the chunk.
/// This keeps `.caf` capture assets visible without guessing a `.m4a` filename.
nonisolated enum MeetingAudioPresentation {
    static func relativePlaybackPath(for chunk: MeetingAudioChunk) -> String? {
        if let archive = chunk.playbackArchiveAsset, archive.presence == .ready,
           !archive.relativeFilePath.isEmpty
        {
            return archive.relativeFilePath
        }
        guard chunk.finalizationState == .finalized, chunk.byteCount > 0,
              !chunk.relativeFilePath.isEmpty else { return nil }
        return chunk.relativeFilePath
    }

    static func firstPlaybackURL(
        in session: MeetingSession,
        directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        for chunk in session.audioTracks
            .flatMap(\.chunks)
            .sorted(by: { $0.sequence < $1.sequence })
        {
            guard let relativePath = relativePlaybackPath(for: chunk) else { continue }
            guard let url = try? MeetingChunkPathConfinement.containedURL(
                sessionDirectory: directory,
                relativePath: relativePath
            ) else { continue }
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
