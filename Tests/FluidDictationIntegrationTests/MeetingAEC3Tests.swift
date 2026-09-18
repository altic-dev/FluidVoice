#if DEBUG

@testable import FluidVoice_Debug
import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import XCTest

final class MeetingAEC3Tests: XCTestCase {
    private let token = MeetingAECStreamToken(generation: 7, identity: 11)

    private func block(
        _ kind: MeetingAECInputKind,
        start: Int64,
        count: Int,
        value: Float = 0.1,
        epoch: CMTimeEpoch = 0,
        token: MeetingAECStreamToken? = nil,
        format: MeetingAECPCMFormat = .monoPlanar
    ) -> MeetingAECPCMBlock {
        MeetingAECPCMBlock(
            kind: kind,
            stream: token ?? self.token,
            presentationTime: CMTime(value: start, timescale: 48_000, flags: .valid, epoch: epoch),
            duration: CMTime(value: CMTimeValue(count), timescale: 48_000),
            samples: [Float](repeating: value, count: count),
            sourceFormat: format
        )
    }

    private func paired(_ emissions: [MeetingAECJoinerEmission]) -> [MeetingAECJoinedFrame] {
        emissions.compactMap {
            if case let .paired(frame) = $0 { return frame }
            return nil
        }
    }

    func testRouteProtectionSkipsSupersededRevisionBeforeDebounce() {
        XCTAssertTrue(MeetingCaptureOwnershipGate.shouldRunRouteProtection(
            taskRevision: 8, currentRevision: 8, stopping: false
        ))
        XCTAssertFalse(MeetingCaptureOwnershipGate.shouldRunRouteProtection(
            taskRevision: 7, currentRevision: 8, stopping: false
        ))
        XCTAssertFalse(MeetingCaptureOwnershipGate.shouldRunRouteProtection(
            taskRevision: 8, currentRevision: 8, stopping: true
        ))
    }

    func testPendingStreamPublicationClassifiesSupersessionAndCandidateDeath() {
        XCTAssertEqual(MeetingCaptureOwnershipGate.mayPublishReplacement(
            authorizedRevision: 3,
            currentRevision: 3,
            stopping: false,
            candidateFailed: false,
            ownsExpectedOldStream: true,
            ownsPendingCandidate: true
        ), .commit)
        XCTAssertEqual(MeetingCaptureOwnershipGate.mayPublishReplacement(
            authorizedRevision: 3,
            currentRevision: 4,
            stopping: false,
            candidateFailed: false,
            ownsExpectedOldStream: true,
            ownsPendingCandidate: true
        ), .superseded)
        XCTAssertEqual(MeetingCaptureOwnershipGate.mayPublishReplacement(
            authorizedRevision: 3,
            currentRevision: 3,
            stopping: false,
            candidateFailed: true,
            ownsExpectedOldStream: true,
            ownsPendingCandidate: true
        ), .failed)
    }

    func testAECCommitRequiresExactLiveOwnershipAndNoTransitionOwner() {
        let reserved = MeetingCaptureStreamOwnership(
            streamIdentity: 11, streamGeneration: 4, routeRevision: 9
        )
        func mayCommit(
            current: MeetingCaptureStreamOwnership = reserved,
            rebuilding: Bool = false,
            stopped: Bool = false
        ) -> Bool {
            MeetingCaptureOwnershipGate.mayCommitAEC(
                reserved: reserved,
                current: current,
                stopping: false,
                rebuilding: rebuilding,
                currentStreamStopped: stopped,
                routeListenerDegraded: false,
                dispositionIsSupportedSpeaker: true,
                activationGeneration: 12,
                reservationToken: 12
            )
        }

        XCTAssertTrue(mayCommit())
        XCTAssertFalse(mayCommit(rebuilding: true))
        XCTAssertFalse(mayCommit(stopped: true))
        XCTAssertFalse(mayCommit(current: MeetingCaptureStreamOwnership(
            streamIdentity: 22, streamGeneration: 5, routeRevision: 9
        )))
    }

    func testDirectAEC3AvailabilityIsEnabledUnlessKillSwitchIsEngaged() {
        XCTAssertTrue(MeetingDirectAEC3Availability.isAvailable(
            killSwitchEngaged: false
        ))
        XCTAssertFalse(MeetingDirectAEC3Availability.isAvailable(
            killSwitchEngaged: true
        ))
    }

    func testRouteClassifierRequiresTwoStablePositiveSnapshots() {
        let speaker = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: false,
            isBuiltIn: true,
            isHeadphonesDataSource: false
        )
        let headphones = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: false,
            isBuiltIn: true,
            isHeadphonesDataSource: true
        )
        let external = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: false,
            isBuiltIn: false,
            isHeadphonesDataSource: false
        )
        let missing = MeetingOutputRouteSnapshot(
            deviceExists: false,
            isBluetooth: false,
            isBuiltIn: false,
            isHeadphonesDataSource: false
        )
        let bluetoothSpeaker = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: true,
            isBuiltIn: true,
            isHeadphonesDataSource: false
        )
        let bluetoothHeadphones = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: true,
            isBuiltIn: false,
            isHeadphonesDataSource: false,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )
        let wiredHeadphones = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: false,
            isBuiltIn: false,
            isHeadphonesDataSource: false,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )

        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: speaker, second: speaker, revisionStayedStable: true
        ), .supportedSpeaker)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: headphones, second: headphones, revisionStayedStable: true
        ), .physicallyClosed)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: speaker, second: speaker, revisionStayedStable: false
        ), .ambiguous)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: speaker, second: headphones, revisionStayedStable: true
        ), .ambiguous)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: external, second: external, revisionStayedStable: true
        ), .ambiguous)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: missing, second: missing, revisionStayedStable: true
        ), .ambiguous)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: bluetoothSpeaker, second: bluetoothSpeaker, revisionStayedStable: true
        ), .ambiguous)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: bluetoothHeadphones, second: bluetoothHeadphones, revisionStayedStable: true
        ), .physicallyClosed)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: wiredHeadphones, second: wiredHeadphones, revisionStayedStable: true
        ), .physicallyClosed)
        XCTAssertEqual(MeetingAECOutputRouteClassifier.classify(
            first: speaker, second: speaker, revisionStayedStable: true, debugDisabled: true
        ), .ambiguous)
    }

    func testArbitrary512FrameBlocksReblockAndAttestExactly() {
        var joiner = MeetingAECStreamJoiner()
        var frames: [MeetingAECJoinedFrame] = []
        var start: Int64 = 12_345
        for _ in 0..<188 {
            frames += self.paired(joiner.append(self.block(.render, start: start, count: 512)))
            frames += self.paired(joiner.append(self.block(.capture, start: start, count: 512)))
            start += 512
        }
        XCTAssertEqual(frames.count, 200)
        XCTAssertEqual(frames.first?.render.presentationTime.value, 12_345)
        XCTAssertEqual(frames.last?.capture.presentationTime.value, 12_345 + 199 * 480)
        XCTAssertFalse(frames[198].clockAttested)
        XCTAssertTrue(frames[199].clockAttested)
        XCTAssertEqual(frames[199].pairedFrameCount, 200)
        XCTAssertTrue(frames.allSatisfy { $0.render.samples.count == 480 && $0.capture.samples.count == 480 })
    }

    func testMicFirstAndRenderFirstProduceSameOrderedPTS() {
        func run(micFirst: Bool) -> [CMTime] {
            var joiner = MeetingAECStreamJoiner()
            var result: [MeetingAECJoinedFrame] = []
            for index in 0..<5 {
                let start = Int64(index * 480)
                let inputs = micFirst
                    ? [self.block(.capture, start: start, count: 480), self.block(.render, start: start, count: 480)]
                    : [self.block(.render, start: start, count: 480), self.block(.capture, start: start, count: 480)]
                for input in inputs { result += self.paired(joiner.append(input)) }
            }
            return result.map(\.capture.presentationTime)
        }
        XCTAssertEqual(run(micFirst: true), run(micFirst: false))
    }

    func testDeliveredDigitalSilenceIsCoverageNotMissingData() {
        var joiner = MeetingAECStreamJoiner()
        var frames: [MeetingAECJoinedFrame] = []
        for index in 0..<201 {
            let start = Int64(index * 480)
            frames += self.paired(joiner.append(self.block(.render, start: start, count: 480, value: 0)))
            frames += self.paired(joiner.append(self.block(.capture, start: start, count: 480)))
        }
        XCTAssertEqual(frames.count, 201)
        XCTAssertTrue(frames.last?.clockAttested == true)
        XCTAssertEqual(joiner.diagnostics.resets, 0)
    }

    func testMissingRenderGapFlushesCaptureRawAndResets() {
        var joiner = MeetingAECStreamJoiner()
        _ = joiner.append(self.block(.render, start: 0, count: 480))
        _ = joiner.append(self.block(.capture, start: 0, count: 480))
        let emissions = joiner.append(self.block(.capture, start: 480, count: 5_280))
        XCTAssertTrue(emissions.contains { if case .reset(.renderLate) = $0 { return true }; return false })
        XCTAssertGreaterThan(joiner.diagnostics.bypassFrames, 0)
        XCTAssertEqual(joiner.diagnostics.retainedCaptureSamples, 0)
    }

    func testEpochAndStreamIdentityChangesReset() {
        var epochJoiner = MeetingAECStreamJoiner()
        _ = epochJoiner.append(self.block(.render, start: 0, count: 480, epoch: 1))
        let epoch = epochJoiner.append(self.block(.capture, start: 0, count: 480, epoch: 2))
        XCTAssertTrue(epoch.contains { if case .reset(.timestampEpochChanged) = $0 { return true }; return false })

        var streamJoiner = MeetingAECStreamJoiner()
        _ = streamJoiner.append(self.block(.render, start: 0, count: 480))
        let changed = self.block(
            .capture,
            start: 0,
            count: 480,
            token: MeetingAECStreamToken(generation: 8, identity: 11)
        )
        let stream = streamJoiner.append(changed)
        XCTAssertTrue(stream.contains { if case .reset(.streamChanged) = $0 { return true }; return false })
    }

    func testSourceFormatChangeResetsBeforePairing() {
        var joiner = MeetingAECStreamJoiner()
        _ = joiner.append(self.block(
            .render,
            start: 0,
            count: 480,
            format: MeetingAECPCMFormat(channelCount: 2, interleaved: true)
        ))
        let emissions = joiner.append(self.block(
            .render,
            start: 480,
            count: 480,
            format: .monoPlanar
        ))
        XCTAssertTrue(emissions.contains { if case .reset(.formatChanged) = $0 { return true }; return false })
    }

    func testOneSampleAnchorResidualIsToleratedButTwoSamplesReset() {
        var oneSample = MeetingAECStreamJoiner()
        _ = oneSample.append(self.block(.render, start: 0, count: 480))
        let accepted = oneSample.append(self.block(.render, start: 481, count: 480))
        XCTAssertFalse(accepted.contains { if case .reset = $0 { return true }; return false })

        var twoSamples = MeetingAECStreamJoiner()
        _ = twoSamples.append(self.block(.render, start: 0, count: 480))
        let rejected = twoSamples.append(self.block(.render, start: 482, count: 480))
        XCTAssertTrue(rejected.contains { if case .reset(.timestampGap) = $0 { return true }; return false })
    }

    func testFractionalAnchorResidualIsComparedBeforeSampleRounding() {
        var joiner = MeetingAECStreamJoiner()
        let first = MeetingAECPCMBlock(
            kind: .render,
            stream: self.token,
            presentationTime: .zero,
            duration: CMTime(value: 480, timescale: 48_000),
            samples: [Float](repeating: 0.1, count: 480)
        )
        // 1,925 / 192,000 seconds is 481.25 samples after the anchor: outside the
        // one-sample contract even though integer conversion would round the delta to 481.
        let drifted = MeetingAECPCMBlock(
            kind: .render,
            stream: self.token,
            presentationTime: CMTime(value: 1_925, timescale: 192_000),
            duration: CMTime(value: 480, timescale: 48_000),
            samples: [Float](repeating: 0.1, count: 480)
        )
        _ = joiner.append(first)
        XCTAssertTrue(joiner.append(drifted).contains {
            if case .reset(.timestampGap) = $0 { return true }
            return false
        })
    }

    func testGapOverlapBackwardAndDivergingSourceGridsResetPrecisely() {
        var gap = MeetingAECStreamJoiner()
        _ = gap.append(self.block(.render, start: 0, count: 480))
        XCTAssertTrue(gap.append(self.block(.render, start: 482, count: 480)).contains {
            if case .reset(.timestampGap) = $0 { return true }
            return false
        })

        var overlap = MeetingAECStreamJoiner()
        _ = overlap.append(self.block(.render, start: 0, count: 480))
        XCTAssertTrue(overlap.append(self.block(.render, start: 478, count: 480)).contains {
            if case .reset(.timestampOverlap) = $0 { return true }
            return false
        })

        var backward = MeetingAECStreamJoiner()
        _ = backward.append(self.block(.render, start: 480, count: 480))
        XCTAssertTrue(backward.append(self.block(.render, start: 0, count: 480)).contains {
            if case .reset(.timestampMovedBackward) = $0 { return true }
            return false
        })

        // Each source is individually within its one-sample fixed-anchor tolerance, but their
        // opposite drift creates a two-sample common-grid residual and must reset the epoch.
        var divergent = MeetingAECStreamJoiner()
        _ = divergent.append(self.block(.render, start: 0, count: 480))
        _ = divergent.append(self.block(.capture, start: 0, count: 480))
        _ = divergent.append(self.block(.render, start: 481, count: 480))
        let divergence = divergent.append(self.block(.capture, start: 479, count: 480))
        XCTAssertTrue(divergence.contains {
            if case .reset(.clockResidualExceeded) = $0 { return true }
            return false
        })
        XCTAssertEqual(divergence.filter { if case .reset = $0 { return true }; return false }.count, 1)
    }

    func testTwentyMillisecondMissingRenderCannotAccumulateNonadjacentAttestation() {
        var joiner = MeetingAECStreamJoiner()
        var beforeGap: [MeetingAECJoinedFrame] = []
        for index in 0..<100 {
            let start = Int64(index * 480)
            beforeGap += self.paired(joiner.append(self.block(.render, start: start, count: 480)))
            beforeGap += self.paired(joiner.append(self.block(.capture, start: start, count: 480)))
        }
        _ = joiner.append(self.block(.capture, start: 100 * 480, count: 960))
        let gap = joiner.append(self.block(.render, start: 102 * 480, count: 480))
        XCTAssertTrue(gap.contains { if case .reset(.timestampGap) = $0 { return true }; return false })

        var afterGap: [MeetingAECJoinedFrame] = []
        for index in 0..<199 {
            let start = Int64(200_000 + index * 480)
            afterGap += self.paired(joiner.append(self.block(.render, start: start, count: 480)))
            afterGap += self.paired(joiner.append(self.block(.capture, start: start, count: 480)))
        }
        XCTAssertEqual(beforeGap.count + afterGap.count, 299)
        XCTAssertEqual(afterGap.last?.pairedFrameCount, 199)
        XCTAssertFalse(afterGap.last?.clockAttested ?? true)

        let finalStart = Int64(200_000 + 199 * 480)
        _ = joiner.append(self.block(.render, start: finalStart, count: 480))
        let final = self.paired(joiner.append(self.block(.capture, start: finalStart, count: 480)))
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.pairedFrameCount, 200)
        XCTAssertTrue(final.first?.clockAttested == true)
    }

    func testPCMBlocksAndSynthesizedOutputsOwnTheirBytes() throws {
        var sourceSamples = [Float](repeating: 0.25, count: 480)
        let block = MeetingAECPCMBlock(
            kind: .capture,
            stream: self.token,
            presentationTime: .zero,
            duration: CMTime(value: 480, timescale: 48_000),
            samples: sourceSamples
        )
        sourceSamples[0] = -0.75
        XCTAssertEqual(block.samples[0], 0.25)

        var synthesizedSource = [Float](repeating: 0.4, count: 480)
        let synthesized = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: synthesizedSource,
            presentationTime: CMTime(value: 9_600, timescale: 48_000)
        ))
        synthesizedSource = [Float](repeating: -0.4, count: 480)
        let extracted = try MeetingAECPCMAdapter.extract(
            synthesized,
            kind: .capture,
            stream: self.token
        ).get()
        XCTAssertEqual(extracted.samples.first, 0.4)
        XCTAssertEqual(extracted.presentationTime, CMTime(value: 9_600, timescale: 48_000))
        XCTAssertEqual(extracted.duration, CMTime(value: 480, timescale: 48_000))
        _ = synthesizedSource
    }

    func testBlockAndSampleBoundsFailDeterministically() {
        var blockBound = MeetingAECStreamJoiner()
        var final: [MeetingAECJoinerEmission] = []
        for index in 0..<65 {
            final = blockBound.append(self.block(.render, start: Int64(index), count: 1))
        }
        XCTAssertTrue(final.contains { if case .reset(.callbackBlockLimit) = $0 { return true }; return false })

        var sampleBound = MeetingAECStreamJoiner()
        let oversized = sampleBound.append(self.block(.render, start: 0, count: 24_001))
        XCTAssertTrue(oversized.contains { if case .reset(.retainedSampleLimit) = $0 { return true }; return false })
    }

    func testInterleavedStereoDownmixAndOwningSynthesis() throws {
        let source = try XCTUnwrap(Self.interleavedBuffer(
            left: [0.8, 0.6, -0.4],
            right: [0.2, -0.2, 0.4],
            pts: CMTime(value: 99, timescale: 48_000)
        ))
        let extracted = try MeetingAECPCMAdapter.extract(source, kind: .render, stream: self.token).get()
        self.assertFloatArraysEqual(extracted.samples, [0.5, 0.2, 0], accuracy: 0.000_001)
        let owned = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: extracted.samples,
            presentationTime: extracted.presentationTime
        ))
        let copied = try MeetingAECPCMAdapter.extract(owned, kind: .capture, stream: self.token).get()
        XCTAssertEqual(copied.samples, extracted.samples)
        XCTAssertEqual(copied.presentationTime, extracted.presentationTime)
    }

    func testPlanarStereoDownmix() throws {
        let source = try XCTUnwrap(Self.planarBuffer(
            left: [1, 0.4, -0.8],
            right: [-0.4, 0.2, 0.2],
            pts: CMTime(value: 123, timescale: 48_000)
        ))
        let extracted = try MeetingAECPCMAdapter.extract(source, kind: .render, stream: self.token).get()
        self.assertFloatArraysEqual(extracted.samples, [0.3, 0.3, -0.3], accuracy: 0.000_001)
        XCTAssertEqual(extracted.presentationTime.value, 123)
    }

    func testAdapterRejectsRateDurationAndNonfiniteInput() throws {
        let wrongRate = try XCTUnwrap(Self.interleavedBuffer(
            left: [0.1, 0.2], right: [0.1, 0.2], pts: .zero, sampleRate: 44_100
        ))
        XCTAssertEqual(
            MeetingAECPCMAdapter.extract(wrongRate, kind: .render, stream: self.token),
            .failure(.unsupportedSampleRate)
        )
        let nonfinite = try XCTUnwrap(Self.interleavedBuffer(
            left: [.nan, 0.2], right: [0.1, 0.2], pts: .zero
        ))
        XCTAssertEqual(
            MeetingAECPCMAdapter.extract(nonfinite, kind: .render, stream: self.token),
            .failure(.nonFiniteSamples)
        )
        let wrongDuration = try XCTUnwrap(Self.interleavedBuffer(
            left: [0.1, 0.2],
            right: [0.1, 0.2],
            pts: .zero,
            sampleDuration: CMTime(value: 2, timescale: 48_000)
        ))
        XCTAssertEqual(
            MeetingAECPCMAdapter.extract(wrongDuration, kind: .render, stream: self.token),
            .failure(.invalidDuration)
        )
        let invalidPTS = try XCTUnwrap(Self.interleavedBuffer(
            left: [0.1, 0.2], right: [0.1, 0.2], pts: .invalid
        ))
        XCTAssertEqual(
            MeetingAECPCMAdapter.extract(invalidPTS, kind: .render, stream: self.token),
            .failure(.invalidTimestamp)
        )
    }

    func testBridgeIdentityOrderingFiniteBoundsAndReset() throws {
        let processor = try MeetingAECProcessor()
        XCTAssertEqual(processor.upstreamRevision, MeetingAECConstants.provenance.upstreamRevision)
        XCTAssertEqual(processor.configurationID, MeetingAECConstants.provenance.bridgeConfigurationID)
        let render = (0..<480).map { 0.25 * sin(Float($0) * 2 * .pi / 80) }
        let capture = render.map { $0 * 0.5 }
        let first = try processor.process(render: render, capture: capture)
        XCTAssertEqual(first.statistics.renderFrames, 1)
        XCTAssertEqual(first.statistics.captureFrames, 1)
        XCTAssertTrue(first.samples.allSatisfy { $0.isFinite && (-1...1).contains($0) })
        try processor.reset()
        let afterReset = try processor.process(render: render, capture: capture)
        XCTAssertEqual(afterReset.statistics.renderFrames, 1)
        XCTAssertEqual(afterReset.statistics.captureFrames, 1)
        XCTAssertGreaterThanOrEqual(afterReset.statistics.resets, 1)
        XCTAssertThrowsError(try processor.process(render: [.nan] + [Float](repeating: 0, count: 479), capture: capture))
    }

    func testAECProvenanceIsBackwardCompatibleAndSoftwareProtectionAdmits() throws {
        XCTAssertTrue(MeetingMicrophoneEchoProtection.softwareEchoCancelled.admitsTranscript)
        let legacy = """
        {"method":"screenCaptureKit","roleAtElection":"unknown","echoProtection":"unprotected","startSeconds":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MeetingCaptureEra.self, from: legacy)
        XCTAssertNil(decoded.aecProvenance)

        var track = Self.microphoneTrack()
        MeetingAECOutputCommitter.applyEra(
            to: &track,
            protection: .softwareEchoCancelled,
            provenance: MeetingAECConstants.provenance,
            startSeconds: 2
        )
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .softwareEchoCancelled)
        XCTAssertEqual(track.captureEras?.last?.aecProvenance, MeetingAECConstants.provenance)
        XCTAssertEqual(track.captureEras?.count, 2)

        let eras = [
            MeetingCaptureEra(
                method: .screenCaptureKit, deviceUID: nil, deviceName: nil,
                roleAtElection: .personal, echoProtection: .unprotected,
                startSeconds: -.infinity
            ),
            MeetingCaptureEra(
                method: .screenCaptureKit, deviceUID: nil, deviceName: nil,
                roleAtElection: .personal, echoProtection: .softwareEchoCancelled,
                startSeconds: 2, aecProvenance: MeetingAECConstants.provenance
            ),
            MeetingCaptureEra(
                method: .screenCaptureKit, deviceUID: nil, deviceName: nil,
                roleAtElection: .personal, echoProtection: .unprotected,
                startSeconds: 4
            ),
        ]
        XCTAssertTrue(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(
            start: 2.1, end: 3.9, eras: eras
        ))
        XCTAssertFalse(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(
            start: 1.9, end: 2.1, eras: eras
        ))
        XCTAssertFalse(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(
            start: 3.9, end: 4.1, eras: eras
        ))
    }

    func testPipelinePromotesOnlyOnFrame201AndBridgeFailureDemotes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-aec3-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try MeetingAudioChunkWriter(
            track: Self.microphoneTrack(),
            sessionDirectory: directory,
            chunkDuration: 60,
            eventHandler: { _ in }
        )
        let gate = MeetingMicrophoneTranscriptGate(.unprotected)
        let live = AECLiveRecorder()
        let failures = AECTerminalRecorder()
        let committer = MeetingAECOutputCommitter(
            writer: writer,
            transcriptGate: gate,
            liveAudioHandler: { _, sample in live.append(sample) },
            terminalFailure: { failure in failures.append(failure) }
        )
        let processor = AECFakeProcessor()
        let pipeline = MeetingAECPipeline(processor: processor, committer: committer)

        for frame in 0..<200 {
            let pts = CMTime(value: CMTimeValue(frame * 480), timescale: 48_000)
            let render = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
                samples: [Float](repeating: 0.2, count: 480), presentationTime: pts
            ))
            let capture = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
                samples: [Float](repeating: 0.1, count: 480), presentationTime: pts
            ))
            pipeline.consumeRender(render, stream: self.token)
            pipeline.consumeCapture(capture, stream: self.token)
            if frame.isMultiple(of: 8) { _ = await writer.snapshot() }
        }
        var track = await writer.snapshot()
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .unprotected)
        XCTAssertEqual(live.count, 0)

        let promotionPTS = CMTime(value: 200 * 480, timescale: 48_000)
        pipeline.consumeRender(try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.2, count: 480), presentationTime: promotionPTS
        )), stream: self.token)
        pipeline.consumeCapture(try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.1, count: 480), presentationTime: promotionPTS
        )), stream: self.token)
        await committer.waitForPendingCommits()
        track = await writer.snapshot()
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .softwareEchoCancelled)
        XCTAssertEqual(track.captureEras?.last?.aecProvenance, MeetingAECConstants.provenance)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(try live.firstMean(token: self.token), 0.35, accuracy: 0.000_01)

        processor.failNext = true
        let failurePTS = CMTime(value: 201 * 480, timescale: 48_000)
        pipeline.consumeRender(try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.2, count: 480), presentationTime: failurePTS
        )), stream: self.token)
        pipeline.consumeCapture(try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.1, count: 480), presentationTime: failurePTS
        )), stream: self.token)
        await committer.waitForPendingCommits()
        track = await writer.snapshot()
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .unprotected)
        XCTAssertNil(track.captureEras?.last?.aecProvenance)
        XCTAssertEqual(
            track.captureEras?.map(\.startSeconds), [0, 2, 2.01],
            "the demotion era must be ordered after the protected era on the sample timeline"
        )
        XCTAssertEqual(live.count, 1, "the bridge-failure raw frame must not reach live ASR")
        XCTAssertTrue(failures.values.isEmpty)

        pipeline.stop(boundary: gate.invalidate())
        await committer.waitForPendingCommits()
        _ = await writer.stop()
    }

    func testPromotionPersistenceFailureKeepsReturnedTrackUnprotected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-aec3-persist-test-\(UUID().uuidString)", isDirectory: true)
        let trackDirectory = directory
            .appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent("microphone", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: trackDirectory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let writer = try MeetingAudioChunkWriter(
            track: Self.microphoneTrack(),
            sessionDirectory: directory,
            chunkDuration: 60,
            eventHandler: { _ in }
        )
        let failures = AECTerminalRecorder()
        let committer = MeetingAECOutputCommitter(
            writer: writer,
            transcriptGate: MeetingMicrophoneTranscriptGate(.unprotected),
            liveAudioHandler: nil,
            terminalFailure: { failure in failures.append(failure) }
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: trackDirectory.path
        )
        let sample = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.1, count: 480),
            presentationTime: CMTime(value: 480, timescale: 48_000)
        ))
        committer.commitProcessed(sample, mayPromote: true)
        await committer.waitForPendingCommits()
        let track = await writer.snapshot()
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .unprotected)
        XCTAssertEqual(failures.values, [.metadataPersistence])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: trackDirectory.path
        )
        _ = await writer.stop()
    }

    func testActivationControllerStartupTransitionTable() {
        var controller = MeetingAECActivationController()
        XCTAssertEqual(controller.state, .raw)
        XCTAssertTrue(controller.allowsInitialCaptureStart(hasCandidate: false))
        XCTAssertFalse(controller.allowsInitialCaptureStart(hasCandidate: true))
        XCTAssertFalse(controller.armReadyCandidate())
        XCTAssertFalse(controller.observeValidatedFormat(kind: .render, token: 0))

        guard let token = controller.reserveConstruction() else {
            return XCTFail("raw state must accept a construction reservation")
        }
        XCTAssertEqual(controller.state, .constructing(token))
        XCTAssertNil(controller.reserveConstruction(), "overlapping construction must be rejected")
        XCTAssertFalse(controller.allowsInitialCaptureStart(hasCandidate: false))

        controller.abandonConstruction(token &+ 1)
        XCTAssertEqual(controller.state, .constructing(token), "stale abandon must be a no-op")
        XCTAssertFalse(controller.commitCandidate(token &+ 1))
        XCTAssertTrue(controller.commitCandidate(token))
        XCTAssertEqual(controller.state, .ready(token))
        XCTAssertTrue(controller.allowsInitialCaptureStart(hasCandidate: true))
        XCTAssertFalse(controller.allowsInitialCaptureStart(hasCandidate: false))

        XCTAssertTrue(controller.armReadyCandidate())
        XCTAssertEqual(controller.state, .armed(token, renderValidated: false, captureValidated: false))
        XCTAssertFalse(controller.armReadyCandidate(), "arming twice must be rejected")
        XCTAssertFalse(controller.allowsInitialCaptureStart(hasCandidate: true))

        XCTAssertFalse(controller.observeValidatedFormat(kind: .render, token: token))
        XCTAssertEqual(controller.state, .armed(token, renderValidated: true, captureValidated: false))
        XCTAssertFalse(controller.observeValidatedFormat(kind: .render, token: token &+ 1))
        XCTAssertEqual(
            controller.state,
            .armed(token, renderValidated: true, captureValidated: false),
            "a stale first-format token must not advance the armed handshake"
        )
        XCTAssertTrue(controller.observeValidatedFormat(kind: .capture, token: token))
        XCTAssertEqual(controller.state, .active(token))
        XCTAssertFalse(controller.observeValidatedFormat(kind: .render, token: token))
        XCTAssertFalse(controller.allowsInitialCaptureStart(hasCandidate: true))

        controller.invalidate()
        XCTAssertEqual(controller.state, .raw)
        XCTAssertNotEqual(controller.generation, token)
        XCTAssertFalse(controller.commitCandidate(token))
        XCTAssertFalse(controller.observeValidatedFormat(kind: .capture, token: token))
        XCTAssertFalse(controller.armReadyCandidate())
    }

    /// Route/stream/lifecycle invalidation immediately before or after every startup step must
    /// drop the handshake to raw and reject the stale token's next transition.
    func testActivationControllerInvalidationBetweenEveryStartupStep() {
        for completedSteps in 0...4 {
            var controller = MeetingAECActivationController()
            var token: UInt64 = 0
            for step in 0...completedSteps {
                switch step {
                case 0:
                    token = controller.reserveConstruction()!
                case 1:
                    XCTAssertTrue(controller.commitCandidate(token))
                case 2:
                    XCTAssertTrue(controller.armReadyCandidate())
                case 3:
                    XCTAssertFalse(controller.observeValidatedFormat(kind: .render, token: token))
                default:
                    XCTAssertTrue(controller.observeValidatedFormat(kind: .capture, token: token))
                }
            }
            controller.invalidate()
            XCTAssertEqual(controller.state, .raw, "step \(completedSteps)")
            XCTAssertFalse(controller.commitCandidate(token), "step \(completedSteps)")
            XCTAssertFalse(controller.armReadyCandidate(), "step \(completedSteps)")
            XCTAssertFalse(controller.observeValidatedFormat(kind: .render, token: token), "step \(completedSteps)")
            XCTAssertFalse(controller.observeValidatedFormat(kind: .capture, token: token), "step \(completedSteps)")
            XCTAssertTrue(controller.allowsInitialCaptureStart(hasCandidate: false), "step \(completedSteps)")
            if let fresh = controller.reserveConstruction() {
                XCTAssertNotEqual(fresh, token, "step \(completedSteps)")
                controller.abandonConstruction(fresh)
                XCTAssertEqual(controller.state, .raw, "step \(completedSteps)")
            } else {
                XCTFail("a fresh reservation must succeed after invalidation (step \(completedSteps))")
            }
        }
    }

    func testTranscriptGateConditionalPromotionSurvivesOnlyWithoutInterveningInvalidation() {
        let gate = MeetingMicrophoneTranscriptGate(.unprotected)
        let epoch = gate.invalidationEpoch
        XCTAssertTrue(gate.updateIfNotInvalidated(.acousticallyClosed, since: epoch))
        XCTAssertTrue(gate.admitsTranscript())

        _ = gate.invalidate()
        XCTAssertFalse(gate.admitsTranscript())
        XCTAssertFalse(
            gate.updateIfNotInvalidated(.acousticallyClosed, since: epoch),
            "a pre-invalidation epoch must never reopen the gate"
        )
        XCTAssertFalse(gate.admitsTranscript())

        let fresh = gate.invalidationEpoch
        XCTAssertNotEqual(fresh, epoch)
        XCTAssertTrue(gate.updateIfNotInvalidated(.acousticallyClosed, since: fresh))
        XCTAssertTrue(gate.admitsTranscript())
    }

    func testFlushPreservesAlreadyProcessedPairsAndEmitsRawTailWithExactPTS() {
        var joiner = MeetingAECStreamJoiner()
        var frames: [MeetingAECJoinedFrame] = []
        for index in 0..<2 {
            let start = Int64(index * 480)
            frames += self.paired(joiner.append(self.block(.render, start: start, count: 480)))
            frames += self.paired(joiner.append(self.block(.capture, start: start, count: 480)))
        }
        frames += self.paired(joiner.append(self.block(.render, start: 960, count: 480)))
        frames += self.paired(joiner.append(self.block(.capture, start: 960, count: 720)))

        let flushed = joiner.flush(reason: .stopped)
        let flushedPairs = self.paired(flushed)
        XCTAssertEqual(frames.count, 3, "every complete pair must drain immediately on the hot path")
        XCTAssertEqual(frames.last?.capture.presentationTime, CMTime(value: 960, timescale: 48_000))
        XCTAssertTrue(flushedPairs.isEmpty, "stop must not duplicate a pair already emitted")

        let bypasses = flushed.compactMap { emission -> MeetingAECBypassSlice? in
            guard case let .bypass(slice, .stopped) = emission else { return nil }
            return slice
        }
        XCTAssertEqual(bypasses.count, 1)
        XCTAssertEqual(bypasses.first?.samples.count, 240, "the incomplete tail is emitted raw without padding")
        XCTAssertEqual(bypasses.first?.presentationTime, CMTime(value: 1_440, timescale: 48_000))
        XCTAssertTrue(flushed.contains { if case .reset(.stopped) = $0 { return true }; return false })
        XCTAssertEqual(joiner.diagnostics.retainedCaptureSamples, 0)
        XCTAssertEqual(joiner.diagnostics.retainedRenderSamples, 0)
    }

    /// A reset zeroes the warm-up count: 150 pairs + reset + 200 pairs reaches attestation only at
    /// the new epoch's own frame 200, so lifetime call counts can never fabricate promotion.
    func testWarmUpRestartsFromZeroAfterReset() {
        var joiner = MeetingAECStreamJoiner()
        var frames: [MeetingAECJoinedFrame] = []
        for index in 0..<150 {
            let start = Int64(index * 480)
            frames += self.paired(joiner.append(self.block(.render, start: start, count: 480)))
            frames += self.paired(joiner.append(self.block(.capture, start: start, count: 480)))
        }
        XCTAssertEqual(frames.count, 150)
        let gap = joiner.append(self.block(.render, start: 150 * 480 + 2, count: 480))
        XCTAssertTrue(gap.contains { if case .reset(.timestampGap) = $0 { return true }; return false })

        var freshFrames: [MeetingAECJoinedFrame] = []
        for index in 0..<200 {
            let start = Int64(1_000_000 + index * 480)
            freshFrames += self.paired(joiner.append(self.block(.render, start: start, count: 480)))
            freshFrames += self.paired(joiner.append(self.block(.capture, start: start, count: 480)))
        }
        XCTAssertEqual(freshFrames.count, 200)
        XCTAssertEqual(freshFrames.first?.pairedFrameCount, 1)
        XCTAssertFalse(freshFrames[198].clockAttested)
        XCTAssertTrue(freshFrames[199].clockAttested)
        XCTAssertEqual(freshFrames[199].pairedFrameCount, 200)
    }

    func testWriterQueueOverflowAppliesSingleEmergencyFailClosedDemotion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-aec3-overflow-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var seeded = Self.microphoneTrack()
        MeetingAECOutputCommitter.applyEra(
            to: &seeded,
            protection: .softwareEchoCancelled,
            provenance: MeetingAECConstants.provenance,
            startSeconds: 1
        )
        let writer = try MeetingAudioChunkWriter(
            track: seeded,
            sessionDirectory: directory,
            chunkDuration: 60,
            eventHandler: { _ in },
            pendingSlotLimit: 0
        )
        let sample = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.1, count: 480),
            presentationTime: CMTime(value: 96_000, timescale: 48_000)
        ))
        XCTAssertFalse(writer.enqueue(sample), "a saturated writer must refuse plain enqueues")

        let completions = AECCompletionRecorder()
        writer.enqueueMetadata(
            failClosed: true,
            mutate: { track in
                MeetingAECOutputCommitter.applyEra(
                    to: &track, protection: .unprotected, provenance: nil, startSeconds: 2
                )
            },
            completion: { completions.append($0) }
        )
        writer.enqueueMetadata(
            failClosed: true,
            mutate: { track in
                MeetingAECOutputCommitter.applyEra(
                    to: &track, protection: .unprotected, provenance: nil, startSeconds: 3
                )
            },
            completion: { completions.append($0) }
        )
        // The snapshot is queued behind the single allowed emergency command on the serial queue.
        let track = await writer.snapshot()
        XCTAssertEqual(completions.count, 2)
        XCTAssertTrue(completions.allFailedWithQueueFull)
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .unprotected)
        XCTAssertEqual(track.captureEras?.last?.startSeconds, 2)
        XCTAssertEqual(
            track.captureEras?.count, 3,
            "the second overlapping fail-closed command must not run its own emergency write"
        )
        _ = await writer.stop()
    }

    func testCommitterWriterOverflowDemotesInMemoryAndReportsQueueBound() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-aec3-committer-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var seeded = Self.microphoneTrack()
        MeetingAECOutputCommitter.applyEra(
            to: &seeded,
            protection: .softwareEchoCancelled,
            provenance: MeetingAECConstants.provenance,
            startSeconds: 1
        )
        let writer = try MeetingAudioChunkWriter(
            track: seeded,
            sessionDirectory: directory,
            chunkDuration: 60,
            eventHandler: { _ in },
            pendingSlotLimit: 0
        )
        let gate = MeetingMicrophoneTranscriptGate(.softwareEchoCancelled)
        let failures = AECTerminalRecorder()
        let committer = MeetingAECOutputCommitter(
            writer: writer,
            transcriptGate: gate,
            liveAudioHandler: nil,
            terminalFailure: { failure in failures.append(failure) }
        )
        let sample = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.1, count: 480),
            presentationTime: CMTime(value: 96_000, timescale: 48_000)
        ))
        committer.commitProcessed(sample, mayPromote: false)
        await committer.waitForPendingCommits()
        let track = await writer.snapshot()
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .unprotected)
        XCTAssertNil(track.captureEras?.last?.aecProvenance)
        XCTAssertEqual(failures.values, [.writerQueueFull])
        XCTAssertFalse(gate.admitsTranscript())
        _ = await writer.stop()
    }

    func testCommitterPromotionQueueFullStaysUnprotectedAndReportsQueueBound() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-aec3-promotion-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try MeetingAudioChunkWriter(
            track: Self.microphoneTrack(),
            sessionDirectory: directory,
            chunkDuration: 60,
            eventHandler: { _ in },
            pendingSlotLimit: 0
        )
        let gate = MeetingMicrophoneTranscriptGate(.unprotected)
        let live = AECLiveRecorder()
        let failures = AECTerminalRecorder()
        let committer = MeetingAECOutputCommitter(
            writer: writer,
            transcriptGate: gate,
            liveAudioHandler: { _, sample in live.append(sample) },
            terminalFailure: { failure in failures.append(failure) }
        )
        let sample = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.1, count: 480),
            presentationTime: CMTime(value: 96_000, timescale: 48_000)
        ))
        committer.commitProcessed(sample, mayPromote: true)
        await committer.waitForPendingCommits()
        let track = await writer.snapshot()
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .unprotected)
        XCTAssertEqual(track.captureEras?.count, 1, "a failed promotion must not append an era")
        XCTAssertEqual(failures.values, [.writerQueueFull])
        XCTAssertFalse(gate.admitsTranscript())
        XCTAssertEqual(live.count, 0)
        _ = await writer.stop()
    }

    /// An invalidation landing after a promotion was enqueued but before its persistence
    /// completes must keep the gate closed and leave the final era unprotected.
    func testPromotionInvalidatedBeforePersistenceCompletionNeverOpens() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-aec3-race-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try MeetingAudioChunkWriter(
            track: Self.microphoneTrack(),
            sessionDirectory: directory,
            chunkDuration: 60,
            eventHandler: { _ in }
        )
        let gate = MeetingMicrophoneTranscriptGate(.unprotected)
        let live = AECLiveRecorder()
        let failures = AECTerminalRecorder()
        let committer = MeetingAECOutputCommitter(
            writer: writer,
            transcriptGate: gate,
            liveAudioHandler: { _, sample in live.append(sample) },
            terminalFailure: { failure in failures.append(failure) }
        )
        let sample = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
            samples: [Float](repeating: 0.1, count: 480),
            presentationTime: CMTime(value: 96_000, timescale: 48_000)
        ))
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await writer.updateTrackMetadata { _ in
                writerEntered.signal()
                _ = releaseWriter.wait(timeout: .now() + 5)
            }
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 2), .success)
        committer.commitProcessed(sample, mayPromote: true)
        committer.invalidateForExternalBoundary(nil)
        releaseWriter.signal()
        try await blocker.value
        await committer.waitForPendingCommits()
        let track = await writer.snapshot()
        XCTAssertEqual(track.captureEras?.last?.echoProtection, .unprotected)
        XCTAssertNil(track.captureEras?.last?.aecProvenance)
        XCTAssertFalse(gate.admitsTranscript())
        XCTAssertEqual(live.count, 0)
        XCTAssertTrue(failures.values.isEmpty)
        _ = await writer.stop()
    }

    func testFirstPromotedLiveFrameCannotBeOvertakenByLaterCallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-aec3-live-order-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try MeetingAudioChunkWriter(
            track: Self.microphoneTrack(),
            sessionDirectory: directory,
            chunkDuration: 60,
            eventHandler: { _ in }
        )
        let recorder = AECBlockingLiveRecorder()
        let committer = MeetingAECOutputCommitter(
            writer: writer,
            transcriptGate: MeetingMicrophoneTranscriptGate(.unprotected),
            liveAudioHandler: { _, sample in recorder.append(sample) },
            terminalFailure: { _ in }
        )
        func sample(_ value: Int64) throws -> CMSampleBuffer {
            try XCTUnwrap(MeetingAECPCMAdapter.synthesize(
                samples: [Float](repeating: 0.1, count: 480),
                presentationTime: CMTime(value: value, timescale: 48_000)
            ))
        }

        committer.commitProcessed(try sample(480), mayPromote: true)
        XCTAssertTrue(recorder.waitUntilFirstHandlerStarts())
        // This callback runs while the promotion handler is deliberately blocked. It must still
        // observe promotionPending and therefore cannot overtake the first live frame.
        committer.commitProcessed(try sample(960), mayPromote: false)
        recorder.releaseFirstHandler()
        await committer.waitForPendingCommits()
        _ = await writer.snapshot()

        committer.commitProcessed(try sample(1_440), mayPromote: false)
        _ = await writer.snapshot()
        XCTAssertEqual(recorder.presentationValues, [480, 1_440])
        _ = await writer.stop()
    }

    private static func microphoneTrack() -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: [],
            captureMethod: .screenCaptureKit,
            captureEras: [MeetingCaptureEra(
                method: .screenCaptureKit,
                deviceUID: "mic",
                deviceName: "Mic",
                roleAtElection: .personal,
                echoProtection: .unprotected,
                startSeconds: 0
            )]
        )
    }

    private static func interleavedBuffer(
        left: [Float],
        right: [Float],
        pts: CMTime,
        sampleRate: Double = 48_000,
        sampleDuration: CMTime? = nil
    ) -> CMSampleBuffer? {
        guard left.count == right.count, !left.isEmpty else { return nil }
        let interleaved = zip(left, right).flatMap { [$0.0, $0.1] }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        guard interleaved.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }) == noErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: sampleDuration
                ?? CMTime(value: 1, timescale: CMTimeScale(sampleRate.rounded())),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: left.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private static func planarBuffer(
        left: [Float],
        right: [Float],
        pts: CMTime
    ) -> CMSampleBuffer? {
        guard left.count == right.count, !left.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 48_000,
                  channels: 2,
                  interleaved: false
              ),
              let pcm = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(left.count)
              ),
              let channels = pcm.floatChannelData
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(left.count)
        channels[0].update(from: left, count: left.count)
        channels[1].update(from: right, count: right.count)

        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: left.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            bufferList: pcm.mutableAudioBufferList
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

private final nonisolated class AECFakeProcessor: MeetingAECProcessing, @unchecked Sendable {
    let upstreamRevision = MeetingAECConstants.provenance.upstreamRevision
    let configurationID = MeetingAECConstants.provenance.bridgeConfigurationID
    var failNext = false
    private var frames: UInt64 = 0
    private var resets: UInt64 = 0

    func process(render: [Float], capture: [Float]) throws
        -> (samples: [Float], statistics: MeetingAECBridgeStatistics)
    {
        if self.failNext {
            self.failNext = false
            throw MeetingAECFailure.bridgeProcessing
        }
        self.frames += 1
        return (
            capture.map { min(1, $0 + 0.25) },
            MeetingAECBridgeStatistics(
                renderFrames: self.frames,
                captureFrames: self.frames,
                resets: self.resets,
                estimatedDelayMilliseconds: nil,
                residualEchoLikelihood: nil
            )
        )
    }

    func reset() throws {
        self.frames = 0
        self.resets += 1
    }
}

private final nonisolated class AECLiveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []

    var count: Int { self.lock.withLock { self.samples.count } }

    func append(_ sample: CMSampleBuffer) {
        self.lock.withLock { self.samples.append(sample) }
    }

    func firstMean(token: MeetingAECStreamToken) throws -> Float {
        let sample = try self.lock.withLock { () throws -> CMSampleBuffer in
            guard let first = self.samples.first else { throw MeetingAECFailure.invalidSampleBuffer }
            return first
        }
        let block = try MeetingAECPCMAdapter.extract(sample, kind: .capture, stream: token).get()
        return block.samples.reduce(0, +) / Float(block.samples.count)
    }
}

private final nonisolated class AECBlockingLiveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let firstHandlerStarted = DispatchSemaphore(value: 0)
    private let firstHandlerRelease = DispatchSemaphore(value: 0)
    private var invocationCount = 0
    private var values: [CMTimeValue] = []

    var presentationValues: [CMTimeValue] { self.lock.withLock { self.values } }

    func append(_ sample: CMSampleBuffer) {
        let isFirst = self.lock.withLock { () -> Bool in
            self.invocationCount += 1
            return self.invocationCount == 1
        }
        if isFirst {
            self.firstHandlerStarted.signal()
            _ = self.firstHandlerRelease.wait(timeout: .now() + 5)
        }
        let value = CMSampleBufferGetPresentationTimeStamp(sample).value
        self.lock.withLock { self.values.append(value) }
    }

    func waitUntilFirstHandlerStarts() -> Bool {
        self.firstHandlerStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstHandler() {
        self.firstHandlerRelease.signal()
    }
}

private final nonisolated class AECCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Void, Error>] = []

    var count: Int { self.lock.withLock { self.results.count } }

    var allFailedWithQueueFull: Bool {
        self.lock.withLock {
            !self.results.isEmpty && self.results.allSatisfy {
                guard case let .failure(error) = $0 else { return false }
                return (error as? MeetingAudioChunkWriter.SequencedCommandError) == .queueFull
            }
        }
    }

    func append(_ result: Result<Void, Error>) {
        self.lock.withLock { self.results.append(result) }
    }
}

private final nonisolated class AECTerminalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MeetingAECFailure] = []
    var values: [MeetingAECFailure] { self.lock.withLock { self.storage } }
    func append(_ failure: MeetingAECFailure) { self.lock.withLock { self.storage.append(failure) } }
}

private extension XCTestCase {
    func assertFloatArraysEqual(
        _ lhs: [Float],
        _ rhs: [Float],
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (left, right) in zip(lhs, rhs) {
            XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
        }
    }
}

#endif
