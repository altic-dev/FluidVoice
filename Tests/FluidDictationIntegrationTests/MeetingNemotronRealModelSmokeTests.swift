import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: opt-in smoke test of the real
/// Nemotron path — the supplied mlpackage, the production runtime's diarization phase, real audio.
/// Runs only when FLUIDVOICE_NEMOTRON_SMOKE_TEST=1 is set; never in CI. It asserts structure
/// (loads, runs, fresh per-epoch state, bounded segments), never model quality.
@MainActor
final class MeetingNemotronRealModelSmokeTests: XCTestCase {
    private func writeSmokeWAV(into directory: URL, seconds: Double = 6.0) throws -> (url: URL, samples: [Float]) {
        let sampleRate: Double = 16_000
        let frameCount = AVAudioFrameCount((seconds * sampleRate).rounded())
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        )!
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let data = buffer.floatChannelData![0]
        // Two voiced bursts of different pitches separated by silence: structure only, not speech.
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let inFirstBurst = t >= 0.5 && t < 2.5
            let inSecondBurst = t >= 3.5 && t < 5.5
            let frequency: Float = inFirstBurst ? 180 : (inSecondBurst ? 320 : 0)
            data[frame] = frequency > 0
                ? 0.4 * sin(2 * Float.pi * frequency * Float(frame) / 16_000)
                : 0
        }
        let url = directory.appendingPathComponent("smoke.wav")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(frameCount)))
        return (url, samples)
    }

    /// Opt-in parity probe: runs the production diarizer on real recordings and writes every
    /// segment to JSON, so the app can be compared with NVIDIA's NeMo reference on the same audio.
    /// Set FLUIDVOICE_NEMOTRON_PARITY_AUDIO (comma-separated 16 kHz mono WAVs),
    /// FLUIDVOICE_NEMOTRON_PARITY_MODEL (.mlpackage) and FLUIDVOICE_NEMOTRON_PARITY_OUT (JSON path).
    func testProductionDiarizerSegmentsForParity() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioList = environment["FLUIDVOICE_NEMOTRON_PARITY_AUDIO"],
              let modelPath = environment["FLUIDVOICE_NEMOTRON_PARITY_MODEL"],
              let outputPath = environment["FLUIDVOICE_NEMOTRON_PARITY_OUT"]
        else {
            throw XCTSkip("set the FLUIDVOICE_NEMOTRON_PARITY_* variables to run the parity probe")
        }
        #if arch(arm64)
        let locator = MeetingNemotronModelLocator(injectedURL: URL(fileURLWithPath: modelPath))
        let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { ASRService() }, modelLocator: locator)
        let audioURLs = audioList.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        var report: [String: [[Double]]] = [:]
        _ = try await runtime.withNemotronDiarization(artifact: try locator.locate()) { factory in
            for url in audioURLs {
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
                XCTAssertEqual(file.processingFormat.channelCount, 1)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                ))
                try file.read(into: buffer)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
                let segments = try await factory.makeDiarizer(epoch: epoch).diarize(samples: samples)
                report[url.lastPathComponent] = segments.map { [Double($0.slotIndex), $0.start, $0.end] }
            }
            return MeetingNemotronPhaseResult()
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath))
        #else
        throw XCTSkip("the production runtime is Apple-Silicon only")
        #endif
    }

    /// Opt-in threshold probe for the cross-epoch voice matcher: cuts each recording where the app
    /// cut it, diarizes every piece with fresh state, and writes each slot's voice embeddings.
    /// FLUIDVOICE_VOICE_PROBE_SPEC is a JSON list of {"audio": path, "cuts": [seconds]};
    /// FLUIDVOICE_NEMOTRON_PARITY_MODEL is the .mlpackage; FLUIDVOICE_VOICE_PROBE_OUT is the output.
    func testVoiceProfilesAcrossEpochsForThresholdProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let specPath = environment["FLUIDVOICE_VOICE_PROBE_SPEC"],
              let modelPath = environment["FLUIDVOICE_NEMOTRON_PARITY_MODEL"],
              let outputPath = environment["FLUIDVOICE_VOICE_PROBE_OUT"]
        else {
            throw XCTSkip("set the FLUIDVOICE_VOICE_PROBE_* variables to run the voice probe")
        }
        #if arch(arm64)
        struct Track: Decodable {
            let audio: String
            let cuts: [Double]
        }
        let tracks = try JSONDecoder().decode([Track].self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
        let locator = MeetingNemotronModelLocator(injectedURL: URL(fileURLWithPath: modelPath))
        let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { ASRService() }, modelLocator: locator)
        var report: [[String: Any]] = []
        for track in tracks {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: track.audio))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let bounds = [0] + track.cuts.map { Int($0 * 16_000) } + [samples.count]
            let trackID = UUID()
            let phase = try await runtime.withNemotronDiarization(artifact: try locator.locate()) { factory in
                var result = MeetingNemotronPhaseResult()
                for piece in 0..<(bounds.count - 1) {
                    let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: piece)
                    let pieceSamples = Array(samples[bounds[piece]..<bounds[piece + 1]])
                    let segments = try await factory.makeDiarizer(epoch: epoch).diarize(samples: pieceSamples)
                    result.voiceSamples += MeetingSpeakerVoiceSamples.collect(
                        epoch: epoch, samples: pieceSamples, segments: segments
                    )
                    let offset = Double(bounds[piece]) / 16_000
                    result.activity += segments.map {
                        MeetingBackendSpeakerActivity(
                            token: MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-\($0.slotIndex)"),
                            start: $0.start + offset,
                            end: $0.end + offset
                        )
                    }
                }
                return result
            }
            let profiles = try await runtime.speakerVoiceProfiles(samples: phase.voiceSamples)
            report.append([
                "audio": track.audio,
                "activity": phase.activity.map {
                    ["piece": $0.token.analysisEpochID.ordinal, "label": $0.token.label, "start": $0.start, "end": $0.end]
                },
                "profiles": profiles.map {
                    ["piece": $0.token.analysisEpochID.ordinal, "label": $0.token.label, "embeddings": $0.embeddings]
                },
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath))
        #else
        throw XCTSkip("the production runtime is Apple-Silicon only")
        #endif
    }

    func testRealNemotronModelDiarizesWithFreshStatePerEpoch() async throws {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_NEMOTRON_SMOKE_TEST"] == "1" else {
            throw XCTSkip("set FLUIDVOICE_NEMOTRON_SMOKE_TEST=1 to run the real-model smoke test")
        }
        let environment = ProcessInfo.processInfo.environment
        let modelURL: URL
        if let override = environment[MeetingNemotronModelLocator.environmentOverrideKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            modelURL = URL(fileURLWithPath: override)
        } else {
            modelURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // FluidDictationIntegrationTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("nemotron-3-diarization/models/nemotron_diar_fp16.mlpackage")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("no Nemotron model package at \(modelURL.path)")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemotron-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (_, samples) = try self.writeSmokeWAV(into: directory)

        #if arch(arm64)
        let runtime = MeetingParakeetNemotronRuntime(
            asrServiceProvider: { ASRService() },
            modelLocator: MeetingNemotronModelLocator(
                injectedURL: modelURL,
                environment: environment
            )
        )
        let trackID = UUID()
        let epoch0 = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)
        let epoch1 = MeetingAnalysisEpochID(trackID: trackID, ordinal: 1)
        let duration = Double(samples.count) / 16_000

        let artifact = try MeetingNemotronModelLocator(
            injectedURL: modelURL,
            environment: environment
        ).locate()
        let results = try await runtime.withNemotronDiarization(artifact: artifact) { factory in
            var collected = MeetingNemotronPhaseResult()
            for epoch in [epoch0, epoch1] {
                let diarizer = try await factory.makeDiarizer(epoch: epoch)
                let segments = try await diarizer.diarize(samples: samples)
                // Test-only completion marker; the runtime phase result has no separate
                // success ledger for a valid epoch that happens to contain no speech.
                collected.failures[epoch] = "smokeCompleted"
                collected.activity.append(contentsOf: segments.map {
                    MeetingBackendSpeakerActivity(
                        token: MeetingBackendSpeakerToken(
                            analysisEpochID: epoch,
                            label: "slot-\($0.slotIndex)"
                        ),
                        start: $0.start,
                        end: $0.end
                    )
                })
            }
            return collected
        }

        XCTAssertEqual(Set(results.failures.keys), [epoch0, epoch1])
        for segment in results.activity {
            XCTAssertGreaterThanOrEqual(segment.start, 0, "\(segment.token.analysisEpochID)")
            XCTAssertGreaterThan(segment.end, segment.start, "\(segment.token.analysisEpochID)")
            XCTAssertLessThanOrEqual(
                segment.end,
                duration + 0.5,
                "\(segment.token.analysisEpochID): segments stay inside the audio"
            )
        }
        #else
        throw XCTSkip("the production runtime is Apple-Silicon only")
        #endif
    }
}
