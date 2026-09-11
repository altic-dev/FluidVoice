import AVFoundation
import CoreMedia
import Foundation

enum CallAudioSource: Sendable, Equatable {
    case microphone
    case system
}

struct CapturedAudioTrack: Sendable {
    let source: CallAudioSource
    let url: URL
    let startOffsetSeconds: Double
}

struct CapturedCallAudio: Sendable {
    let directoryURL: URL
    let fileName: String
    let tracks: [CapturedAudioTrack]

    var timelineAnchorSeconds: Double {
        self.tracks.map(\.startOffsetSeconds).min() ?? 0
    }

    func relativeStart(for track: CapturedAudioTrack) -> Double {
        max(0, track.startOffsetSeconds - self.timelineAnchorSeconds)
    }

    func remove() {
        CallCaptureSession.removeRecordingDirectory(at: self.directoryURL)
    }
}

/// Persists the two aligned capture tracks as one mixed call recording.
final nonisolated class CallRecordingStore: @unchecked Sendable {
    static let shared = CallRecordingStore()

    private let fileManager = FileManager.default

    private init() {}

    func save(_ audio: CapturedCallAudio) async throws -> URL {
        let directory = try self.recordingsDirectory()
        let destinationURL = directory
            .appendingPathComponent("\(audio.fileName)-\(UUID().uuidString.prefix(6)).m4a")
        let composition = AVMutableComposition()
        let mix = AVMutableAudioMix()
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        do {
            for capturedTrack in audio.tracks {
                let asset = AVURLAsset(url: capturedTrack.url)
                guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                      let compositionTrack = composition.addMutableTrack(
                          withMediaType: .audio,
                          preferredTrackID: kCMPersistentTrackID_Invalid
                      )
                else { continue }

                let duration = try await asset.load(.duration)
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceTrack,
                    at: CMTime(seconds: audio.relativeStart(for: capturedTrack), preferredTimescale: 48_000)
                )
                let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(0.5, at: .zero)
                inputParameters.append(parameters)
            }

            guard !inputParameters.isEmpty,
                  let exporter = AVAssetExportSession(
                      asset: composition,
                      presetName: AVAssetExportPresetAppleM4A
                  )
            else {
                throw CallTranscriptionError.audioWriterFailed("Could not prepare the call recording export.")
            }

            mix.inputParameters = inputParameters
            exporter.audioMix = mix
            try await exporter.export(to: destinationURL, as: .m4a)
            return destinationURL
        } catch {
            try? self.fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func deleteIfOwned(path: String?) {
        guard let path,
              let directory = try? self.recordingsDirectory(createIfNeeded: false)
        else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent == directory.standardizedFileURL,
              url.pathExtension.lowercased() == "m4a"
        else { return }
        try? self.fileManager.removeItem(at: url)
    }

    private func recordingsDirectory(createIfNeeded: Bool = true) throws -> URL {
        guard let base = self.fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CallTranscriptionError.audioWriterFailed("Could not access Application Support.")
        }
        let directory = base
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent("CallRecordings", isDirectory: true)
        if createIfNeeded {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
