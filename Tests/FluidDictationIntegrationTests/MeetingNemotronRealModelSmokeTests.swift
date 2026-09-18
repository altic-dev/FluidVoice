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
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
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
                    segment.end, duration + 0.5,
                    "\(segment.token.analysisEpochID): segments stay inside the audio"
                )
            }
        #else
            throw XCTSkip("the production runtime is Apple-Silicon only")
        #endif
    }
}
