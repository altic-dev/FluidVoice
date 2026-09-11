import AVFoundation
import CryptoKit
import Foundation

/// Local offline evaluator. Compile with MeetingPlaybackDuplicateDetector.swift. No ASR/model
/// loading, networking, original-session writes, text/embedding output or app installation.
@main
struct MeetingTemporalShadow {
    struct Stamp: Decodable {
        let value: Double
        let timescale: Double
        var seconds: Double { value / timescale }
    }
    struct Discontinuity: Decodable { let presentationTime: Stamp? }
    struct Chunk: Decodable {
        let id: UUID
        let relativeFilePath: String
        let presentationStart: Stamp
        let presentationEnd: Stamp
        let discontinuities: [Discontinuity]
    }
    struct Track: Decodable { let kind: String; let chunks: [Chunk] }
    struct Session: Decodable { let id: UUID; let audioTracks: [Track] }
    struct InputFingerprint: Codable { let chunkID: UUID; let sha256: String }
    struct SpeechRecord: Encodable {
        let frame: MeetingSpeechActivityDetector<MeetingLocalSileroActivityModel>.Frame
        let temporalState: MeetingSpeechPlaybackShadowPolicy.TemporalContext
        let combinedReason: MeetingSpeechPlaybackShadowPolicy.Reason
        let proposedAdmission = "uncertainCandidate"
        let legacyEchoEvidence = "notMeasured"
    }
    struct Report: Encodable {
        let version = MeetingPlaybackDuplicateDetector.version
        let experimental = true
        let scope = "Offline temporal evidence only; no speech absence/admission/identity conclusions. No enforcement."
        let sessionSHA256: String
        let inputs: [InputFingerprint]
        let configuration: MeetingPlaybackDuplicateDetector.Configuration
        let sampleRate = MeetingPlaybackDuplicateDetector.sampleRate
        let boundaryGuardSeconds = 2.0
        let decoderEdgeGuardSeconds = 0.05
        let controlOffsetSeconds = 8.0
        let minimumCorrelation = 0.25
        let minimumControlMargin = 0.08
        let minimumPeakMargin = 0.025
        let supportWindows = 3
        let holdSeconds = 0
        let durationSeconds: Double
        let unwindowedTailSeconds: Double
        let maximumWindowWallSeconds: Double
        let stateCounts: [String: Int]
        let reasonCounts: [String: Int]
        let windows: [MeetingPlaybackDuplicateDetector.Result]
        let speechModelHashes: [String: String]?
        let speechModelStatus: String
        let speechAdapterVersion = "speech-shadow-b2-v1"
        let speechFrameSampleRate = 16_000
        let speechFrameSamples = 4096
        let speechDiagnosticThreshold = 0.85
        let speechFrames: [SpeechRecord]?
        let speechUnwindowedTailSeconds: Double?
        let speechUnavailableSeconds: Double?
    }
    enum Failure: Error { case invalidInput, unsafePath, decoder, outputExists }

    static func decode(_ url: URL, rate: Double = 2_000) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate >= 2_000,
              format.sampleRate <= 192_000, (1...8).contains(format.channelCount),
              file.length > 0, file.length <= Int64(format.sampleRate * 65),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                              channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(rate * 66)) else {
            throw Failure.decoder
        }
        try file.read(into: input)
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil, status != .error, output.frameLength > 0,
              let samples = output.floatChannelData?[0] else { throw Failure.decoder }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }

    static func main() throws {
        guard (3...4).contains(CommandLine.arguments.count) else { throw Failure.invalidInput }
        let speechEnabled = CommandLine.arguments.count == 4
        var speechModel: MeetingLocalSileroActivityModel?
        var modelHashes: [String: String]?
        var modelFiles: [String: URL] = [:]
        var modelStatus = "off"
        if speechEnabled {
            // Only explicitly selected local compiled models. No default model/download API.
            let modelURL = URL(fileURLWithPath: CommandLine.arguments[3]).resolvingSymlinksInPath()
            do {
                guard modelURL.pathExtension == "mlmodelc",
                      let enumerator = FileManager.default.enumerator(at: modelURL,
                          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                else { throw Failure.invalidInput }
                var hashes: [String: String] = [:], totalBytes = 0
                for case let file as URL in enumerator {
                    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isSymbolicLink != true else { throw Failure.unsafePath }
                    if info.isRegularFile == true {
                        totalBytes += info.fileSize ?? 0
                        guard totalBytes <= 32_000_000, hashes.count < 64 else { throw Failure.invalidInput }
                        let name = String(file.path.dropFirst(modelURL.path.count + 1))
                        hashes[name] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                        modelFiles[name] = file
                    }
                }
                guard !hashes.isEmpty else { throw Failure.invalidInput }
                speechModel = try MeetingLocalSileroActivityModel(modelURL: modelURL)
                modelHashes = hashes; modelStatus = "local-cpu-only-silero-256ms-v6; threshold=0.85; warmup=one-frame"
            } catch { modelStatus = "unavailable-no-download" }
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let root = input.deletingLastPathComponent()
        // Never write a sidecar into the original session directory, even via symlinks.
        let resolvedOutput = output.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(output.lastPathComponent)
        guard !resolvedOutput.path.hasPrefix(root.path + "/"), resolvedOutput != input else { throw Failure.unsafePath }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.outputExists }
        let inputAttributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard let inputBytes = inputAttributes[.size] as? NSNumber,
              inputBytes.intValue <= 16_000_000 else { throw Failure.invalidInput }
        let data = try Data(contentsOf: input)
        let session = try JSONDecoder().decode(Session.self, from: data)
        let chunks = session.audioTracks.flatMap(\.chunks)
        guard !chunks.isEmpty, chunks.count <= 32,
              session.audioTracks.count <= 2,
              Set(session.audioTracks.map(\.kind)).count == session.audioTracks.count,
              session.audioTracks.allSatisfy({ ["microphone", "applicationAudio"].contains($0.kind) }),
              chunks.allSatisfy({ $0.presentationStart.seconds.isFinite && $0.presentationEnd.seconds.isFinite
                  && $0.presentationEnd.seconds > $0.presentationStart.seconds
                  && $0.presentationEnd.seconds - $0.presentationStart.seconds <= 65 }) else { throw Failure.invalidInput }
        let origin = chunks.map { $0.presentationStart.seconds }.min()!
        let duration = chunks.map { $0.presentationEnd.seconds - origin }.max()!
        guard duration > 0, duration <= 600 else { throw Failure.invalidInput }
        // Same either-track boundary definition and ±blockSeconds=2 guard as the pipeline.
        // Missing-PTS discontinuities cannot be placed: fail closed for this offline input.
        let discontinuities = chunks.flatMap(\.discontinuities)
        guard discontinuities.allSatisfy({ $0.presentationTime?.seconds.isFinite == true }) else { throw Failure.invalidInput }
        let boundaries = discontinuities.map { $0.presentationTime!.seconds - origin }.sorted()
        let count = Int(ceil(duration * 2_000))
        var tracks: [String: MeetingPlaybackDuplicateDetector.PCM] = [:]
        var fingerprints: [InputFingerprint] = []
        let speechCount = speechEnabled ? Int(ceil(duration * 16_000)) : 0
        var speechSamples = [Float](repeating: 0, count: speechCount)
        var speechValid = [Bool](repeating: false, count: speechCount)
        var speechOccupied = [Bool](repeating: false, count: speechCount)
        for track in session.audioTracks {
            var samples = [Float](repeating: 0, count: count)
            var valid = [Bool](repeating: false, count: count)
            var occupied = [Bool](repeating: false, count: count)
            for chunk in track.chunks {
                let parts = chunk.relativeFilePath.split(separator: "/", omittingEmptySubsequences: false)
                guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                      !chunk.relativeFilePath.contains("\\") else { throw Failure.unsafePath }
                let url = root.appendingPathComponent(chunk.relativeFilePath).resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/") else { throw Failure.unsafePath }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 32_000_000 else { throw Failure.invalidInput }
                let before = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                let decoded = try decode(url)
                let decodedSpeech = speechEnabled && track.kind == "microphone" ? try decode(url, rate: 16_000) : nil
                let after = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                guard before == after else { throw Failure.invalidInput }
                fingerprints.append(.init(chunkID: chunk.id, sha256: before))
                let start = chunk.presentationStart.seconds - origin
                let end = chunk.presentationEnd.seconds - origin
                if let decodedSpeech {
                    let first = max(0, Int(ceil(start * 16_000))), last = min(speechCount, Int(floor(end * 16_000)))
                    for index in first..<last {
                        let time = Double(index) / 16_000, position = (time - start) * 16_000
                        let lower = Int(floor(position)), alpha = Float(position - floor(position))
                        let usable = time >= start + 0.05 && time < end - 0.05
                            && lower >= 800 && lower + 801 < decodedSpeech.count
                            && !boundaries.contains(where: { abs(time - $0) <= 2 })
                        if speechOccupied[index] { speechValid[index] = false; continue }
                        speechOccupied[index] = true
                        if usable {
                            speechSamples[index] = decodedSpeech[lower] * (1 - alpha) + decodedSpeech[lower + 1] * alpha
                            speechValid[index] = speechSamples[index].isFinite
                        }
                    }
                }
                let first = max(0, Int(ceil(start * 2_000)))
                let last = min(count, Int(floor(end * 2_000)))
                for index in first..<last {
                    let time = Double(index) / 2_000
                    let position = (time - start) * 2_000
                    let lower = Int(floor(position)), alpha = Float(position - floor(position))
                    // Trim declared end, decoded end and conservative codec/converter edges.
                    let usable = time >= start + 0.05 && time < end - 0.05
                        && lower >= 100 && lower + 101 < decoded.count
                        && !boundaries.contains(where: { abs(time - $0) <= 2 })
                    if occupied[index] { valid[index] = false; continue }
                    occupied[index] = true
                    if usable {
                        samples[index] = decoded[lower] * (1 - alpha) + decoded[lower + 1] * alpha
                        valid[index] = samples[index].isFinite
                    }
                }
            }
            tracks[track.kind] = .init(start: 0, samples: samples, valid: valid)
        }
        func slice(_ track: MeetingPlaybackDuplicateDetector.PCM?, start: Double, count: Int,
                   mappedStart: Double? = nil) -> MeetingPlaybackDuplicateDetector.PCM? {
            guard let track else { return nil }
            let first = Int((start * 2_000).rounded())
            var samples = [Float](repeating: 0, count: count), valid = [Bool](repeating: false, count: count)
            for i in 0..<count where first + i >= 0 && first + i < track.samples.count {
                samples[i] = track.samples[first + i]; valid[i] = track.valid[first + i]
            }
            return .init(start: mappedStart ?? start, samples: samples, valid: valid)
        }
        var detector = MeetingPlaybackDuplicateDetector()
        var results: [MeetingPlaybackDuplicateDetector.Result] = []
        for step in 0..<Int(duration / 2) {
            let start = Double(step * 2)
            let epoch = UInt64(boundaries.filter { $0 <= start }.count)
            let referenceStart = start - 0.5
            let nullStart = start + 10.5 <= duration ? referenceStart + 8 : referenceStart - 8
            let nullControl = nullStart >= 0 && nullStart + 3 <= duration
                ? slice(tracks["applicationAudio"], start: nullStart, count: 6_000, mappedStart: referenceStart) : nil
            let mic = slice(tracks["microphone"], start: start, count: 4_000)
                ?? .init(start: start, samples: [], valid: [])
            results.append(detector.process(.init(sessionID: session.id, epoch: epoch, routeID: "recorded",
                start: start, microphone: mic,
                reference: slice(tracks["applicationAudio"], start: referenceStart, count: 6_000),
                mismatchedReference: nullControl)))
        }
        var speechRecords: [SpeechRecord] = []
        if let speechModel {
            var detector = MeetingSpeechActivityDetector(model: speechModel)
            for first in stride(from: 0, through: max(-1, speechCount - 4096), by: 4096) {
                let start = Double(first) / 16_000, epoch = UInt64(boundaries.filter { $0 <= start }.count)
                let frame = detector.process(samples: Array(speechSamples[first..<(first + 4096)]),
                    valid: Array(speechValid[first..<(first + 4096)]), start: start, session: session.id, epoch: epoch, route: "recorded")
                let temporal = MeetingSpeechPlaybackShadowPolicy.temporalContext(start: start, epoch: epoch, windows: results)
                speechRecords.append(.init(frame: frame, temporalState: temporal,
                    combinedReason: MeetingSpeechPlaybackShadowPolicy.reason(activity: frame.active,
                        reliableDuplicate: temporal == .supported)))
            }
        }
        if let modelHashes {
            for (name, file) in modelFiles {
                guard SHA256.hash(data: try Data(contentsOf: file)).map({ String(format: "%02x", $0) }).joined() == modelHashes[name]
                else { throw Failure.invalidInput }
            }
        }
        let report = Report(sessionSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            inputs: fingerprints, configuration: .init(), durationSeconds: duration,
            unwindowedTailSeconds: duration - Double(results.count * 2),
            maximumWindowWallSeconds: results.map(\.elapsedSeconds).max() ?? 0,
            stateCounts: Dictionary(grouping: results, by: { $0.state.rawValue }).mapValues(\.count),
            reasonCounts: Dictionary(grouping: results, by: { $0.reason.rawValue }).mapValues(\.count), windows: results,
            speechModelHashes: modelHashes, speechModelStatus: modelStatus, speechFrames: speechEnabled ? speechRecords : nil,
            speechUnwindowedTailSeconds: speechModel == nil ? nil : duration - Double(speechRecords.count) * 0.256,
            speechUnavailableSeconds: speechEnabled ? duration - Double(speechRecords.filter { $0.frame.probability != nil }.count) * 0.256 : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: [.withoutOverwriting])
        print("Created numeric-only shadow sidecar: \(results.count) windows; no session changes.")
    }
}
