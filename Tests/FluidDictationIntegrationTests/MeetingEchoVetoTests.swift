@testable import FluidVoice_Debug
import AVFoundation
import Foundation
import XCTest

final class MeetingEchoVetoTests: XCTestCase {
    private let sampleRate = 16_000.0

    // MARK: - Fixtures

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingEchoVetoTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes 32-bit float PCM so it round-trips exactly through `readSamples`.
    private func writeAudioFile(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw NSError(domain: "MeetingEchoVetoTests", code: 1)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "MeetingEchoVetoTests", code: 2)
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func makeChunk(
        sequence: Int,
        relativeFilePath: String,
        presentationStart: TimeInterval,
        presentationEnd: TimeInterval,
        discontinuities: [MeetingAudioDiscontinuity] = []
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: relativeFilePath,
            presentationStart: MeetingMediaTime(value: Int64((presentationStart * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((presentationEnd * 1000).rounded()), timescale: 1000),
            discontinuities: discontinuities,
            sha256: "test",
            byteCount: 1,
            finalizationState: .finalized
        )
    }

    private func makeTrack(kind: MeetingAudioTrackKind, chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: kind,
            sourceIdentifier: "src",
            sourceDisplayName: "Source",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks
        )
    }

    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func nextUnit() -> Float {
            self.state = self.state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(self.state >> 11) / Double(1 << 53))
        }
        mutating func nextSigned() -> Float { self.nextUnit() * 2 - 1 }
    }

    private func bandLimitedNoise(count: Int, seed: UInt64) -> [Float] {
        var generator = LCG(seed: seed)
        var white = [Float](repeating: 0, count: count)
        for i in 0..<count { white[i] = generator.nextSigned() }
        var smoothed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let a = white[i]
            let b = i > 0 ? white[i - 1] : 0
            let c = i > 1 ? white[i - 2] : 0
            smoothed[i] = (a + b + c) / 3
        }
        return smoothed
    }

    // MARK: - 1. Reference gathering: straddling two app chunks

    func testReferenceSpansStraddlingTwoAppChunksReturnsBothWithOffsets() {
        let appChunkA = self.makeChunk(sequence: 0, relativeFilePath: "a.caf", presentationStart: 0, presentationEnd: 10)
        let appChunkB = self.makeChunk(sequence: 1, relativeFilePath: "b.caf", presentationStart: 10, presentationEnd: 20)
        // Mic chunk [8, 14) straddles the app boundary at 10.
        let spans = MeetingProcessingPipeline.referenceSpans(
            micSessionRange: (start: 8, end: 14),
            appChunks: [appChunkA, appChunkB],
            origin: 0
        )
        XCTAssertEqual(spans.count, 2)
        let first = try! XCTUnwrap(spans.first { $0.chunk.id == appChunkA.id })
        XCTAssertEqual(first.localRange, 8.0..<10.0, "local coordinates are relative to appChunkA's own start")
        XCTAssertEqual(first.outputOffset, 0, accuracy: 1e-9)

        let second = try! XCTUnwrap(spans.first { $0.chunk.id == appChunkB.id })
        XCTAssertEqual(second.localRange, 0.0..<4.0, "local coordinates are relative to appChunkB's own start")
        XCTAssertEqual(second.outputOffset, 2, accuracy: 1e-9)
    }

    // MARK: - 2. Reference gathering: missing/failed app chunk yields zero-fill

    func testGatherReferenceAudioZeroFillsMissingChunk() throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let goodSamples = self.bandLimitedNoise(count: 16_000, seed: 1)
        let goodURL = dir.appendingPathComponent("good.caf")
        try self.writeAudioFile(samples: goodSamples, sampleRate: self.sampleRate, to: goodURL)

        let goodChunk = self.makeChunk(sequence: 0, relativeFilePath: "good.caf", presentationStart: 0, presentationEnd: 1)
        let missingChunk = self.makeChunk(sequence: 1, relativeFilePath: "missing.caf", presentationStart: 1, presentationEnd: 2)

        let output = MeetingProcessingPipeline.gatherReferenceAudio(
            micSessionRange: (start: 0, end: 2),
            appChunks: [goodChunk, missingChunk],
            origin: 0,
            sessionDirectory: dir,
            sampleRate: self.sampleRate
        )

        XCTAssertEqual(output.count, 32_000)
        // AVAudioFile reads may legitimately short-read (fewer frames than requested); a short
        // read only ever drops the tail, so the head is a reliable, non-flaky probe of "was this
        // chunk actually read". The missing chunk's region must be all zero regardless.
        for (actual, expected) in zip(output.prefix(1_000), goodSamples.prefix(1_000)) {
            XCTAssertEqual(actual, expected, accuracy: 1e-4)
        }
        XCTAssertTrue(output.suffix(1_000).allSatisfy { $0 == 0 }, "a missing chunk's file must zero-fill, not throw")
    }

    // MARK: - 3. Reference gathering: independently rotated chunk boundaries

    func testReferenceSpansMapIndependentlyRotatedBoundariesCorrectly() {
        // Mic rotates every 7s, app rotates every 5s: chunk indices never line up.
        let micChunkSessionRange = (start: 14.0, end: 21.0)
        let appChunks = [
            self.makeChunk(sequence: 0, relativeFilePath: "app0.caf", presentationStart: 0, presentationEnd: 5),
            self.makeChunk(sequence: 1, relativeFilePath: "app1.caf", presentationStart: 5, presentationEnd: 10),
            self.makeChunk(sequence: 2, relativeFilePath: "app2.caf", presentationStart: 10, presentationEnd: 15),
            self.makeChunk(sequence: 3, relativeFilePath: "app3.caf", presentationStart: 15, presentationEnd: 20),
            self.makeChunk(sequence: 4, relativeFilePath: "app4.caf", presentationStart: 20, presentationEnd: 25),
        ]
        let spans = MeetingProcessingPipeline.referenceSpans(
            micSessionRange: micChunkSessionRange, appChunks: appChunks, origin: 0
        )
        // [14,21) intersects app2 [10,15), app3 [15,20), app4 [20,25).
        XCTAssertEqual(Set(spans.map(\.chunk.sequence)), [2, 3, 4])

        let fromApp2 = try! XCTUnwrap(spans.first { $0.chunk.sequence == 2 })
        XCTAssertEqual(fromApp2.localRange, 4.0..<5.0)
        XCTAssertEqual(fromApp2.outputOffset, 0, accuracy: 1e-9)

        let fromApp3 = try! XCTUnwrap(spans.first { $0.chunk.sequence == 3 })
        XCTAssertEqual(fromApp3.localRange, 0.0..<5.0)
        XCTAssertEqual(fromApp3.outputOffset, 1, accuracy: 1e-9)

        let fromApp4 = try! XCTUnwrap(spans.first { $0.chunk.sequence == 4 })
        XCTAssertEqual(fromApp4.localRange, 0.0..<1.0)
        XCTAssertEqual(fromApp4.outputOffset, 6, accuracy: 1e-9)
    }

    // MARK: - 4. Reference read failure produces .unknown and does not throw

    func testComputeEchoVerdictsDegradesToUnknownWhenReferenceIsUnreadable() throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micSamples = self.bandLimitedNoise(count: Int(3.0 * self.sampleRate), seed: 5)
        let micURL = dir.appendingPathComponent("mic.caf")
        try self.writeAudioFile(samples: micSamples, sampleRate: self.sampleRate, to: micURL)
        let micChunk = self.makeChunk(sequence: 0, relativeFilePath: "mic.caf", presentationStart: 0, presentationEnd: 3)

        // The application track's only chunk points at a file that was never written.
        let unreadableAppChunk = self.makeChunk(sequence: 0, relativeFilePath: "does-not-exist.caf", presentationStart: 0, presentationEnd: 3)
        let appTrack = self.makeTrack(kind: .applicationAudio, chunks: [unreadableAppChunk])

        // Must not throw: a sick application-audio track can never take down a healthy mic chunk.
        let outcome = try MeetingProcessingPipeline.computeEchoVerdicts(
            micChunk: micChunk,
            micChunkURL: micURL,
            chunkOffset: 0,
            chunkDuration: 3,
            turns: [(index: 0, start: 0.5, end: 2.5)],
            applicationTrack: appTrack,
            origin: 0,
            sessionDirectory: dir,
            acceptedDelaysInEpoch: []
        )
        // Zero-filled reference has no energy; the scorer can never form a confident delay
        // estimate against silence, so every turn degrades to `.unknown`, never mis-vetoed.
        XCTAssertTrue(outcome.verdicts.values.allSatisfy { $0 == .unknown })
        XCTAssertNil(outcome.acceptedDelaySeconds)
    }

    // MARK: - 5. effectiveEcho matrix

    func testEffectiveEchoMatrix() {
        func turn(isLikelyEcho: Bool, signalVerdict: TurnEchoVerdict) -> MeetingProcessingPipeline.StagedMicrophoneTurn {
            MeetingProcessingPipeline.StagedMicrophoneTurn(
                chunkID: UUID(), index: 0, clusterID: UUID(), clusterLabel: "0",
                start: 0, end: 1, text: "hi", overlapsRemote: true,
                isLikelyEcho: isLikelyEcho, echoScored: true, signalVerdict: signalVerdict
            )
        }
        XCTAssertFalse(turn(isLikelyEcho: true, signalVerdict: .containsLocalSpeech).effectiveEcho)
        XCTAssertTrue(turn(isLikelyEcho: true, signalVerdict: .echo).effectiveEcho)
        XCTAssertTrue(turn(isLikelyEcho: true, signalVerdict: .unknown).effectiveEcho)
        XCTAssertFalse(turn(isLikelyEcho: false, signalVerdict: .containsLocalSpeech).effectiveEcho)
        // Signal-only echo: ASR garbles bleed differently from the far end's own transcript, so
        // text matching misses it while the signal reads it plainly (measured median 0.91).
        XCTAssertTrue(turn(isLikelyEcho: false, signalVerdict: .echo).effectiveEcho)
        XCTAssertFalse(turn(isLikelyEcho: false, signalVerdict: .unknown).effectiveEcho)
    }

    // MARK: - 6. Local-speaker election is unchanged by signal verdicts

    func testLocalSpeakerElectionIsUnchangedBySignalVerdict() {
        let localCluster = UUID()
        let remoteCluster = UUID()
        func turns(signalVerdict: TurnEchoVerdict) -> [MeetingProcessingPipeline.StagedMicrophoneTurn] {
            [
                MeetingProcessingPipeline.StagedMicrophoneTurn(
                    chunkID: UUID(), index: 0, clusterID: localCluster, clusterLabel: "local",
                    start: 0, end: 5, text: "clean local speech", overlapsRemote: false,
                    isLikelyEcho: false, echoScored: false, signalVerdict: signalVerdict
                ),
                MeetingProcessingPipeline.StagedMicrophoneTurn(
                    chunkID: UUID(), index: 1, clusterID: remoteCluster, clusterLabel: "remote",
                    start: 5, end: 6, text: "echoed", overlapsRemote: true,
                    isLikelyEcho: true, echoScored: true, signalVerdict: signalVerdict
                ),
            ]
        }
        let prototypeSpeakerIDs: Set<SessionSpeakerID> = [localCluster, remoteCluster]

        let unknownResult = MeetingProcessingPipeline.selectLocalCluster(
            from: turns(signalVerdict: .unknown), prototypeSpeakerIDs: prototypeSpeakerIDs
        )
        let localSpeechResult = MeetingProcessingPipeline.selectLocalCluster(
            from: turns(signalVerdict: .containsLocalSpeech), prototypeSpeakerIDs: prototypeSpeakerIDs
        )
        let echoResult = MeetingProcessingPipeline.selectLocalCluster(
            from: turns(signalVerdict: .echo), prototypeSpeakerIDs: prototypeSpeakerIDs
        )

        XCTAssertEqual(unknownResult, localCluster)
        XCTAssertEqual(unknownResult, localSpeechResult)
        XCTAssertEqual(unknownResult, echoResult)
    }

    // MARK: - 7. Opposite-sign delays both handled

    func testResolvedDelayHandlesOppositeSignEstimates() {
        let positive = DelayEstimate(seconds: 0.05, confidence: MeetingEchoSignalScorer.minimumDelayConfidence + 1)
        let negative = DelayEstimate(seconds: -0.05, confidence: MeetingEchoSignalScorer.minimumDelayConfidence + 1)
        XCTAssertEqual(MeetingProcessingPipeline.resolvedDelay(estimate: positive, acceptedDelaysInEpoch: []), 0.05)
        XCTAssertEqual(MeetingProcessingPipeline.resolvedDelay(estimate: negative, acceptedDelaysInEpoch: []), -0.05)
    }

    func testComputeEchoVerdictsRecoversNegativeDelayEndToEnd() throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reference = self.bandLimitedNoise(count: Int(3.0 * self.sampleRate), seed: 20)
        // Mic *leads* the reference by 150 samples: a negative delay in `mic - reference` terms.
        let delaySamples = 150
        var mic = [Float](repeating: 0, count: reference.count)
        for i in 0..<reference.count {
            let sourceIndex = i + delaySamples
            mic[i] = sourceIndex < reference.count ? reference[sourceIndex] * 0.5 : 0
        }

        let micURL = dir.appendingPathComponent("mic.caf")
        let refURL = dir.appendingPathComponent("ref.caf")
        try self.writeAudioFile(samples: mic, sampleRate: self.sampleRate, to: micURL)
        try self.writeAudioFile(samples: reference, sampleRate: self.sampleRate, to: refURL)

        let micChunk = self.makeChunk(sequence: 0, relativeFilePath: "mic.caf", presentationStart: 0, presentationEnd: 3)
        let appChunk = self.makeChunk(sequence: 0, relativeFilePath: "ref.caf", presentationStart: 0, presentationEnd: 3)
        let appTrack = self.makeTrack(kind: .applicationAudio, chunks: [appChunk])

        let outcome = try MeetingProcessingPipeline.computeEchoVerdicts(
            micChunk: micChunk,
            micChunkURL: micURL,
            chunkOffset: 0,
            chunkDuration: 3,
            turns: [(index: 0, start: 0.2, end: 2.5)],
            applicationTrack: appTrack,
            origin: 0,
            sessionDirectory: dir,
            acceptedDelaysInEpoch: []
        )
        XCTAssertEqual(outcome.acceptedDelaySeconds ?? .nan, -Double(delaySamples) / self.sampleRate, accuracy: 2.0 / self.sampleRate)
        XCTAssertEqual(outcome.verdicts[0], .echo)
    }

    // MARK: - 8. Checkpoint from any prior pipelineVersion is invalidated

    func testCheckpointWithPriorPipelineVersionIsInvalidated() {
        let sessionID = UUID()
        let trackID = UUID()
        let fingerprint = MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 1, sha256: "x")
        let fingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = [trackID: [fingerprint]]
        let checkpoint = MeetingProcessingCheckpoint(
            version: MeetingProcessingCheckpoint.currentVersion,
            sessionID: sessionID,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion - 1,
            asrProvider: "apple",
            asrModel: "base",
            languageCode: "en",
            completedTrackID: trackID,
            trackFingerprints: fingerprints,
            speakers: [],
            segments: [],
            remoteSpeech: [],
            speakerIDByKey: [:],
            nextRemoteSpeaker: 1,
            nextMicrophoneSpeaker: 1
        )
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom, title: "t", microphone: MeetingMicrophoneIdentity(captureDeviceID: "d", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
        session.id = sessionID

        XCTAssertGreaterThan(MeetingProcessingPipeline.pipelineVersion, 1)
        XCTAssertFalse(checkpoint.isValid(
            session: session,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            provider: "apple",
            model: "base",
            language: "en",
            completedTrackID: trackID,
            expectedFingerprints: fingerprints
        ), "a checkpoint written under pipelineVersion 3 must not resume under pipelineVersion 4's classification rules")
    }
}
