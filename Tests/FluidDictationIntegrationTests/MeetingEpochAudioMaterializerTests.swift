import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§3): epoch materialization against
/// real audio on disk. The manifest is built by the real observer over real WAV files, then the
/// materializer must slice, mono-mix, resample and concatenate exactly those spans — and fail
/// closed when the bytes change underneath it.
@MainActor
final class MeetingEpochAudioMaterializerTests: XCTestCase {
    // MARK: - WAV fixtures

    private struct WrittenChunk {
        let url: URL
        let relativePath: String
        let duration: Double
        let sha256: String
        let byteCount: Int64
    }

    private func writeWAV(
        into sessionDirectory: URL,
        relativePath: String,
        seconds: Double,
        sampleRate: Double = 16_000,
        channels: Int = 1,
        amplitude: Float = 0.5,
        secondHalfAmplitude: Float? = nil
    ) throws -> WrittenChunk {
        let url = sessionDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount((seconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frameCount) {
                let half = frame >= Int(frameCount) / 2
                let amp = half ? (secondHalfAmplitude ?? amplitude) : amplitude
                data[frame] = amp * sin(2 * Float.pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)!.int64Value
        let sha256 = MeetingChunkPathConfinement.sha256Hex(contentsOf: url)!
        return WrittenChunk(
            url: url,
            relativePath: relativePath,
            duration: seconds,
            sha256: sha256,
            byteCount: byteCount
        )
    }

    private struct TrackFixture {
        let session: MeetingSession
        let track: MeetingAudioTrack
        let manifest: MeetingAnalysisManifest
        let directory: URL
    }

    private func makeManifestFixture(
        directory: URL,
        chunks: [(chunk: MeetingAudioChunk, written: WrittenChunk)]
    ) throws -> TrackFixture {
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "microphone",
            sourceDisplayName: "microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks.map(\.chunk),
            captureMethod: .voiceProcessing,
            captureEras: [MeetingCaptureEra(
                method: .voiceProcessing,
                deviceUID: "mic-a",
                deviceName: "mic-a",
                roleAtElection: .unknown,
                echoProtection: .voiceProcessed,
                startSeconds: chunks.map { $0.chunk.presentationStart.seconds }.min() ?? 0
            )]
        )
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom,
                title: "Materializer fixture",
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-a", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            )
        )
        session.audioTracks = [track]
        session.processingAttempts = [MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date(timeIntervalSinceNow: -30),
            completedAt: nil,
            stage: .pending,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )]
        let request = MeetingBackendRequest(
            attemptID: session.processingAttempts.last?.id ?? UUID(),
            session: session,
            sessionDirectory: directory,
            configuration: MeetingFinalProcessingConfiguration(languageCode: "en")
        )
        let plan = MeetingBackendPlan(request: request, descriptor: MeetingParakeetNemotronBackend.descriptor)
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: MeetingChunkAudioObserver(sessionDirectory: directory),
            analysisSampleRate: 16_000
        ).build()
        return TrackFixture(session: session, track: track, manifest: manifest, directory: directory)
    }

    private func makeChunk(
        sequence: Int,
        start: Double,
        end: Double,
        written: WrittenChunk
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: written.relativePath,
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: written.sha256,
            byteCount: written.byteCount,
            finalizationState: .finalized
        )
    }

    // MARK: - Materialization

    func testSlicesMonoMixesResamplesAndConcatenatesInAnalysisOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("materializer-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let first = try self.writeWAV(
            into: directory,
            relativePath: "tracks/microphone/chunk_0.wav",
            seconds: 2.0,
            amplitude: 0.5,
            secondHalfAmplitude: 0.05
        )
        let second = try self.writeWAV(
            into: directory,
            relativePath: "tracks/microphone/chunk_1.wav",
            seconds: 1.0,
            sampleRate: 48_000,
            channels: 2,
            amplitude: 0.3
        )
        let fixture = try self.makeManifestFixture(directory: directory, chunks: [
            (self.makeChunk(sequence: 0, start: 100, end: 102, written: first), first),
            (self.makeChunk(sequence: 1, start: 102, end: 103, written: second), second),
        ])
        let trackManifest = try XCTUnwrap(fixture.manifest.track(fixture.track.id))
        XCTAssertEqual(trackManifest.spans.count, 2, "contiguous chunks share one epoch, two spans")
        let epoch = try XCTUnwrap(trackManifest.epochs.first)
        XCTAssertEqual(trackManifest.epochs.count, 1)

        let materialized = try await MeetingEpochAudioMaterializer().materialize(
            epoch: epoch,
            track: trackManifest,
            manifest: fixture.manifest,
            sessionDirectory: fixture.directory
        )

        XCTAssertEqual(materialized.sampleRate, 16_000)
        XCTAssertEqual(materialized.spanSamples.count, 2)
        XCTAssertEqual(Double(materialized.samples.count), 3.0 * 16_000, accuracy: 64)
        XCTAssertEqual(
            materialized.spanSamples.map(\.spanID),
            epoch.spanIDs,
            "span sample ranges follow analysis order"
        )
        let firstRange = materialized.spanSamples[0].sampleRange
        let secondRange = materialized.spanSamples[1].sampleRange
        XCTAssertEqual(Double(firstRange.count), 2.0 * 16_000, accuracy: 64)
        XCTAssertEqual(Double(secondRange.count), 1.0 * 16_000, accuracy: 64)
        XCTAssertEqual(secondRange.lowerBound, firstRange.upperBound, "concatenated with no hole")

        // Content really came from the files: the first chunk's loud half beats its quiet half.
        let firstHalf = materialized.samples[firstRange.lowerBound..<(firstRange.lowerBound + 16_000)]
        let secondHalf = materialized.samples[(firstRange.lowerBound + 16_000)..<firstRange.upperBound]
        let loudMax = firstHalf.map(abs).max() ?? 0
        let quietMax = secondHalf.map(abs).max() ?? 0
        XCTAssertGreaterThan(loudMax, 0.3)
        XCTAssertLessThan(quietMax, 0.15)
        let resampledMax = materialized.samples[secondRange].map(abs).max() ?? 0
        XCTAssertGreaterThan(resampledMax, 0.15, "the 48k stereo chunk was mixed and resampled")
    }

    func testChangedBytesFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("materializer-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let written = try self.writeWAV(
            into: directory, relativePath: "tracks/microphone/chunk_0.wav", seconds: 1.0
        )
        let fixture = try self.makeManifestFixture(directory: directory, chunks: [
            (self.makeChunk(sequence: 0, start: 100, end: 101, written: written), written),
        ])
        let trackManifest = try XCTUnwrap(fixture.manifest.track(fixture.track.id))
        let epoch = try XCTUnwrap(trackManifest.epochs.first)

        // Rewrite shorter audio: the recorded byte count no longer matches.
        _ = try self.writeWAV(
            into: directory, relativePath: "tracks/microphone/chunk_0.wav", seconds: 0.5
        )
        do {
            _ = try await MeetingEpochAudioMaterializer().materialize(
                epoch: epoch,
                track: trackManifest,
                manifest: fixture.manifest,
                sessionDirectory: fixture.directory
            )
            XCTFail("changed bytes must fail closed")
        } catch MeetingEpochMaterializationError.byteCountChanged {
            // expected
        }

        // Same size, different content: the recorded digest no longer matches.
        _ = try self.writeWAV(
            into: directory, relativePath: "tracks/microphone/chunk_0.wav", seconds: 1.0, amplitude: 0.1
        )
        do {
            _ = try await MeetingEpochAudioMaterializer().materialize(
                epoch: epoch,
                track: trackManifest,
                manifest: fixture.manifest,
                sessionDirectory: fixture.directory
            )
            XCTFail("changed content must fail closed")
        } catch MeetingEpochMaterializationError.hashChanged {
            // expected
        }
    }

    func testMissingFileAndSymlinkFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("materializer-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let written = try self.writeWAV(
            into: directory, relativePath: "tracks/microphone/chunk_0.wav", seconds: 1.0
        )
        let fixture = try self.makeManifestFixture(directory: directory, chunks: [
            (self.makeChunk(sequence: 0, start: 100, end: 101, written: written), written),
        ])
        let trackManifest = try XCTUnwrap(fixture.manifest.track(fixture.track.id))
        let epoch = try XCTUnwrap(trackManifest.epochs.first)

        // Replaced by a symlink to an outside file: confinement rejects it before any read.
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: written.url, to: outside)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: written.url)
        try FileManager.default.createSymbolicLink(at: written.url, withDestinationURL: outside)
        do {
            _ = try await MeetingEpochAudioMaterializer().materialize(
                epoch: epoch,
                track: trackManifest,
                manifest: fixture.manifest,
                sessionDirectory: fixture.directory
            )
            XCTFail("a symlinked chunk must fail closed")
        } catch MeetingEpochMaterializationError.pathRejected {
            // expected
        }

        // Removed entirely: missing, not readable.
        try FileManager.default.removeItem(at: written.url)
        do {
            _ = try await MeetingEpochAudioMaterializer().materialize(
                epoch: epoch,
                track: trackManifest,
                manifest: fixture.manifest,
                sessionDirectory: fixture.directory
            )
            XCTFail("a missing chunk must fail closed")
        } catch MeetingEpochMaterializationError.fileMissing {
            // expected
        }
    }
}
