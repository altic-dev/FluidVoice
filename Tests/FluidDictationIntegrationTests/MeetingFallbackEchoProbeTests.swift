@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Opt-in probe against a real recorded session, used to decide whether the whole-chunk microphone
/// fallback can be classified by the signal scorer. Set FLUIDVOICE_ECHO_PROBE to the session
/// directory to run it.
final class MeetingFallbackEchoProbeTests: XCTestCase {
    func testWholeChunkFallbackVerdictOnRealSession() throws {
        guard let root = ProcessInfo.processInfo.environment["FLUIDVOICE_ECHO_PROBE"] else {
            throw XCTSkip("FLUIDVOICE_ECHO_PROBE not set")
        }
        let sessionDirectory = URL(fileURLWithPath: root, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let micTrack = try decoder.decode(
            MeetingAudioTrack.self,
            from: Data(contentsOf: sessionDirectory.appending(path: "tracks/microphone/track.json"))
        )
        let appTrack = try decoder.decode(
            MeetingAudioTrack.self,
            from: Data(contentsOf: sessionDirectory.appending(path: "tracks/applicationAudio/track.json"))
        )

        let origin = min(
            micTrack.chunks.first?.presentationStart.seconds ?? 0,
            appTrack.chunks.first?.presentationStart.seconds ?? 0
        )

        for chunk in micTrack.chunks {
            let chunkOffset = chunk.presentationStart.seconds - origin
            let chunkDuration = chunk.presentationEnd.seconds - chunk.presentationStart.seconds
            let url = sessionDirectory.appending(path: chunk.relativeFilePath)

            // One turn spanning the whole chunk — exactly what the fallback would score.
            let wholeChunk = [(index: 0, start: chunkOffset, end: chunkOffset + chunkDuration)]
            let outcome = try MeetingProcessingPipeline.computeEchoVerdicts(
                micChunk: chunk,
                micChunkURL: url,
                chunkOffset: chunkOffset,
                chunkDuration: chunkDuration,
                turns: wholeChunk,
                applicationTrack: appTrack,
                origin: origin,
                sessionDirectory: sessionDirectory,
                acceptedDelaysInEpoch: []
            )
            let verdict = outcome.verdicts[0].map { String(describing: $0) } ?? "nil"
            print(String(
                format: "[probe] chunk seq=%d span=[%.1f-%.1f] verdict=%@ delay=%@",
                chunk.sequence, chunkOffset, chunkOffset + chunkDuration, verdict,
                outcome.acceptedDelaySeconds.map { String(format: "%.4fs", $0) } ?? "none"
            ))
        }
    }

    /// Scores specific turns that text-echo detection missed, to see whether the signal scorer
    /// could have caught them. FLUIDVOICE_ECHO_PROBE_TURNS is "label:start:end,label:start:end".
    func testNamedTurnsAgainstSignalScorer() throws {
        guard let root = ProcessInfo.processInfo.environment["FLUIDVOICE_ECHO_PROBE"],
              let spec = ProcessInfo.processInfo.environment["FLUIDVOICE_ECHO_PROBE_TURNS"]
        else { throw XCTSkip("probe env not set") }

        let sessionDirectory = URL(fileURLWithPath: root, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let micTrack = try decoder.decode(
            MeetingAudioTrack.self,
            from: Data(contentsOf: sessionDirectory.appending(path: "tracks/microphone/track.json"))
        )
        let appTrack = try decoder.decode(
            MeetingAudioTrack.self,
            from: Data(contentsOf: sessionDirectory.appending(path: "tracks/applicationAudio/track.json"))
        )
        let origin = min(
            micTrack.chunks.first?.presentationStart.seconds ?? 0,
            appTrack.chunks.first?.presentationStart.seconds ?? 0
        )

        for entry in spec.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard parts.count == 3, let start = Double(parts[1]), let end = Double(parts[2]) else { continue }
            let label = String(parts[0])
            guard let chunk = micTrack.chunks.first(where: {
                let chunkStart = $0.presentationStart.seconds - origin
                let chunkEnd = $0.presentationEnd.seconds - origin
                return start >= chunkStart && start < chunkEnd
            }) else {
                print("[turn] \(label) no chunk covers \(start)")
                continue
            }
            let chunkOffset = chunk.presentationStart.seconds - origin
            let chunkDuration = chunk.presentationEnd.seconds - chunk.presentationStart.seconds
            // Clamp: a turn may run past its chunk, and the scorer reads one chunk's audio.
            let clampedEnd = min(end, chunkOffset + chunkDuration)
            let outcome = try MeetingProcessingPipeline.computeEchoVerdicts(
                micChunk: chunk,
                micChunkURL: sessionDirectory.appending(path: chunk.relativeFilePath),
                chunkOffset: chunkOffset,
                chunkDuration: chunkDuration,
                turns: [(index: 0, start: start, end: clampedEnd)],
                applicationTrack: appTrack,
                origin: origin,
                sessionDirectory: sessionDirectory,
                acceptedDelaysInEpoch: []
            )
            print(String(
                format: "[turn] %-22@ [%.1f-%.1f] verdict=%@ delay=%@",
                label as NSString, start, clampedEnd,
                outcome.verdicts[0].map { String(describing: $0) } ?? "nil",
                outcome.acceptedDelaySeconds.map { String(format: "%.4fs", $0) } ?? "none"
            ))
        }
    }
}
