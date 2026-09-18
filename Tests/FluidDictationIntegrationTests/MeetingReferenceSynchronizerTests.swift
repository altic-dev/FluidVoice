@testable import FluidVoice_Debug
import XCTest

final class MeetingReferenceSynchronizerTests: XCTestCase {
    private let sampleRate = 16_000.0

    private func mic(
        _ sequence: Int,
        start: Int64,
        host: Double? = nil,
        value: Float = 1,
        count: Int = 160,
        route: String = "route-a",
        discontinuity: Bool = false
    ) -> MeetingMicrophonePCMFrame {
        MeetingMicrophonePCMFrame(sequenceNumber: sequence, sampleTime: start, hostTime: host,
            sampleRate: sampleRate, samples: [Float](repeating: value, count: count), routeIdentifier: route,
            discontinuity: discontinuity)
    }

    private func ref(
        _ sequence: Int,
        pts: Double,
        value: Float = 2,
        count: Int = 160,
        rate: Double? = nil,
        discontinuity: Bool = false
    ) -> MeetingReferencePCMFrame {
        MeetingReferencePCMFrame(sequenceNumber: sequence, presentationTime: pts,
            sampleRate: rate ?? sampleRate, samples: [Float](repeating: value, count: count), discontinuity: discontinuity)
    }

    func testExactTenMillisecondFramesAndMasks() {
        let input = MeetingReferenceSynchronizer()
        let result = input.synchronize(
            microphone: (0..<3).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) },
            reference: (0..<3).map { ref($0, pts: Double($0) * 0.01) }
        )
        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.frames.count, 3)
        XCTAssertTrue(result.frames.allSatisfy { $0.captureSamples.count == 160 && $0.renderSamples.count == 160 })
        XCTAssertTrue(result.frames.allSatisfy { $0.captureValidMask.allSatisfy { $0 } && $0.renderValidMask.allSatisfy { $0 } })
        XCTAssertEqual(result.frames.map(\.epochID), [0, 0, 0])
    }

    func testPositiveAndNegativeOffsetHaveExplicitLagSign() {
        let positive = MeetingReferenceSynchronizer(configuration: .init(referenceToMicrophoneOffsetSeconds: 0.02))
            .synchronize(microphone: (0..<5).map { mic($0, start: Int64($0 * 160)) }, reference: (0..<5).map { ref($0, pts: Double($0) * 0.01) })
        let negative = MeetingReferenceSynchronizer(configuration: .init(referenceToMicrophoneOffsetSeconds: -0.02))
            .synchronize(microphone: (0..<5).map { mic($0, start: Int64($0 * 160)) }, reference: (0..<5).map { ref($0, pts: Double($0) * 0.01) })
        XCTAssertTrue(positive.frames.compactMap(\.lagSeconds).allSatisfy { $0 == -0.02 })
        XCTAssertTrue(negative.frames.compactMap(\.lagSeconds).allSatisfy { $0 == 0.02 })
    }

    func testSlowDriftIsReportedAndLargeDriftIsUnknown() {
        let stable = MeetingReferenceSynchronizer(configuration: .init(referenceClockDriftPPM: 25))
            .synchronize(microphone: [mic(0, start: 0)], reference: [ref(0, pts: 0)])
        XCTAssertEqual(stable.diagnostics.referenceClockDriftPPM, 25)
        let unstable = MeetingReferenceSynchronizer(configuration: .init(referenceClockDriftPPM: 90, maximumClockDriftPPM: 100))
            .synchronize(microphone: [mic(0, start: 0)], reference: [ref(0, pts: 0)])
        XCTAssertTrue(unstable.frames[0].unknownReasons.contains(.clockDriftUnstable))
    }

    func testDroppedBlocksCreateGapMaskAndEpoch() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0), mic(2, start: 320)],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01), ref(2, pts: 0.02)]
        )
        XCTAssertTrue(result.frames.contains { $0.unknownReasons.contains(.captureGap) && $0.captureValidMask.contains(false) })
        XCTAssertGreaterThan(result.diagnostics.epochCount, 1)
        XCTAssertEqual(result.frames.map(\.epochID).max(), 1)
    }

    func testCodecPrimingRemainderAndEditListAreAccountedFor() {
        let configuration = MeetingReferenceSynchronizerConfiguration(
            referenceScope: .authorizedFullMix, referenceCompleteness: .measuredComplete,
            codecPrimingSamples: 32, codecRemainderSamples: 16, editListOffsetSeconds: 0.01
        )
        let result = MeetingReferenceSynchronizer(configuration: configuration).synchronize(
            microphone: [mic(0, start: 0), mic(1, start: 160)],
            reference: [ref(0, pts: 0, count: 160), ref(1, pts: 0.01, count: 160)]
        )
        XCTAssertEqual(result.frames.count, 3) // edit-list offset shifts reference one hop
        XCTAssertEqual(result.diagnostics.converterVersions, ["linear-v1", "linear-v1"])
        XCTAssertEqual(result.diagnostics.converterDelays, [0, 0])
        XCTAssertTrue(result.frames.dropFirst().contains { $0.renderValidMask.contains(true) })
    }

    func testDiscontinuityRouteAndSampleRateChangesResetEpoch() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0), mic(1, start: 160, route: "route-b", discontinuity: true), mic(2, start: 320, route: "route-b")],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01, rate: 8_000), ref(2, pts: 0.03, rate: 8_000)]
        )
        // Both tracks reset at the same session boundary, so the merged epoch advances once.
        XCTAssertEqual(
            result.diagnostics.epochCount,
            2,
            "epochIDs=\(result.frames.map(\.epochID)) reasons=\(result.frames.map(\.unknownReasons))"
        )
        XCTAssertGreaterThan(result.frames.map(\.epochID).max() ?? 0, 0)
    }

    func testSynthesizedMicrophoneTimingFreezesUntilResynchronizationBoundary() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [
                mic(0, start: 0, host: nil),
                mic(1, start: 160, host: nil),
                mic(2, start: 320, host: 0.02),
                mic(3, start: 480, host: 0.03)
            ],
            reference: (0..<4).map { ref($0, pts: Double($0) * 0.01) }
        )
        XCTAssertTrue(result.frames.prefix(2).allSatisfy { $0.adaptationFrozen })
        guard let boundary = result.frames.firstIndex(where: { $0.resynchronizationBoundary }) else {
            return XCTFail("expected a recorded resynchronization boundary")
        }
        XCTAssertTrue(result.frames.contains { $0.unknownReasons.contains(.captureTimingSynthesized) })
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertTrue(result.frames.dropFirst(boundary + 1).contains { !$0.adaptationFrozen })
    }

    func testSilenceIsValidAudioAndNotMissingCoverage() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, value: 0)], reference: [ref(0, pts: 0, value: 0)]
        )
        XCTAssertTrue(result.frames[0].captureValidMask.allSatisfy { $0 })
        XCTAssertTrue(result.frames[0].renderValidMask.allSatisfy { $0 })
        XCTAssertFalse(result.frames[0].unknownReasons.contains(.captureGap))
        XCTAssertFalse(result.frames[0].unknownReasons.contains(.referenceGap))
    }

    func testReferenceScopeAndCompletenessRemainSeparateReasons() {
        let result = MeetingReferenceSynchronizer().synchronize(microphone: [mic(0, start: 0)], reference: [ref(0, pts: 0)])
        XCTAssertTrue(result.frames[0].unknownReasons.contains(.referenceScopeLimited))
        XCTAssertTrue(result.frames[0].unknownReasons.contains(.referenceCompletenessUnobservable))
        XCTAssertFalse(result.frames[0].unknownReasons.contains(.referenceAbsent))
    }

    func testMissingReferenceAndMissingCaptureAreUnknownNotSilence() {
        let noReference = MeetingReferenceSynchronizer().synchronize(microphone: [mic(0, start: 0)], reference: [])
        XCTAssertTrue(noReference.frames[0].unknownReasons.contains(.referenceAbsent))
        XCTAssertTrue(noReference.frames[0].renderValidMask.allSatisfy { !$0 })
        let noCapture = MeetingReferenceSynchronizer().synchronize(microphone: [], reference: [ref(0, pts: 0)])
        XCTAssertTrue(noCapture.frames[0].unknownReasons.contains(.captureGap))
        XCTAssertTrue(noCapture.frames[0].captureValidMask.allSatisfy { !$0 })
    }

    func testDeterministicReplayAndBoundedResourceFailOpen() {
        let micFrames = (0..<4).map { mic($0, start: Int64($0 * 160), value: Float($0)) }
        let refs = (0..<4).map { ref($0, pts: Double($0) * 0.01, value: Float($0 + 1)) }
        let synchronizer = MeetingReferenceSynchronizer()
        XCTAssertEqual(synchronizer.synchronize(microphone: micFrames, reference: refs), synchronizer.synchronize(microphone: micFrames, reference: refs))
        let bounded = MeetingReferenceSynchronizer(configuration: .init(maximumInputFrameCount: 1))
            .synchronize(microphone: micFrames, reference: refs)
        XCTAssertTrue(bounded.failedOpen)
        XCTAssertEqual(bounded.failureReason, .engineUnavailable)
        XCTAssertTrue(bounded.diagnostics.boundedResourceFailure)
    }

    func testNonFiniteDuplicateAndLateFramesAreDroppedDeterministically() {
        var invalid = mic(1, start: 160)
        invalid = MeetingMicrophonePCMFrame(sequenceNumber: 1, sampleTime: 160, hostTime: 0.01, sampleRate: sampleRate, samples: [Float.nan] + Array(repeating: 1, count: 159))
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0), invalid, mic(1, start: 320), mic(3, start: 160)],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01), ref(2, pts: 0.02)]
        )
        XCTAssertGreaterThanOrEqual(result.diagnostics.nonFiniteSampleCount, 1)
        XCTAssertGreaterThanOrEqual(result.diagnostics.duplicateOrLateFrameCount, 1)
        XCTAssertGreaterThanOrEqual(result.diagnostics.droppedFrameCount, 2)
        XCTAssertTrue(result.frames.contains { $0.unknownReasons.contains(.captureGap) })
    }

    func testStereoContinuityUsesDownmixedCountAndMalformedArrayIsGap() {
        let stereo = (0..<2).map { index in
            MeetingMicrophonePCMFrame(sequenceNumber: index, sampleTime: Int64(index * 160), hostTime: Double(index) * 0.01,
                sampleRate: sampleRate, channelCount: 2, samples: [Float](repeating: Float(index + 1), count: 320))
        }
        let valid = MeetingReferenceSynchronizer().synchronize(microphone: stereo, reference: [ref(0, pts: 0), ref(1, pts: 0.01)])
        XCTAssertEqual(valid.diagnostics.epochCount, 1)
        XCTAssertEqual(valid.frames.map { $0.captureSamples[0] }, [1, 2])
        XCTAssertFalse(valid.frames.contains { $0.unknownReasons.contains(.captureGap) })

        let malformed = MeetingMicrophonePCMFrame(sequenceNumber: 0, sampleTime: 0, hostTime: 0,
            sampleRate: sampleRate, channelCount: 2, samples: [Float](repeating: 1, count: 319))
        let result = MeetingReferenceSynchronizer().synchronize(microphone: [malformed, stereo[1]], reference: [ref(0, pts: 0), ref(1, pts: 0.01)])
        XCTAssertEqual(result.diagnostics.droppedFrameCount, 1)
        // A malformed pre-origin block cannot define a source gap; the first accepted
        // block establishes the microphone origin and is fully covered.
        XCTAssertTrue(result.frames[0].captureValidMask.allSatisfy { $0 })
        XCTAssertFalse(result.frames[0].unknownReasons.contains(.captureGap))
    }

    func testDriftBeyondConfiguredMaximumFailsOpenAsClockDriftUnstable() {
        let result = MeetingReferenceSynchronizer(configuration: .init(referenceClockDriftPPM: 101, maximumClockDriftPPM: 100))
            .synchronize(microphone: [mic(0, start: 0, host: 0)], reference: [ref(0, pts: 0)])
        XCTAssertTrue(result.failedOpen)
        XCTAssertEqual(result.failureReason, MeetingSynchronizerUnknownReason.clockDriftUnstable)
        XCTAssertFalse(result.diagnostics.boundedResourceFailure)
    }

    func testReferenceEpochAndGapUseTransformedSessionCoordinates() {
        let config = MeetingReferenceSynchronizerConfiguration(
            referenceConverter: .init(algorithmicDelaySeconds: 0.004), referenceToMicrophoneOffsetSeconds: 0.03,
            editListOffsetSeconds: 0.02)
        let refs = [ref(0, pts: 0), ref(1, pts: 0.03, discontinuity: true)]
            + (2..<10).map { ref($0, pts: Double($0 + 2) * 0.01) }
        let result = MeetingReferenceSynchronizer(configuration: config).synchronize(
            microphone: (0..<10).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) }, reference: refs)
        let firstReset = result.frames.firstIndex { $0.epochID > 0 }
        XCTAssertNotNil(firstReset)
        XCTAssertGreaterThanOrEqual(firstReset ?? 0, 5) // transformed event is after 0.05 s, not raw PTS 0.01
        XCTAssertTrue(result.frames.contains { $0.unknownReasons.contains(.referenceGap) && $0.renderValidMask.contains(false) })
    }

    func testFrameTimelinesExposeActualSourceTimesAndMappedLag() {
        let config = MeetingReferenceSynchronizerConfiguration(
            microphoneConverter: .init(algorithmicDelaySeconds: 0.003),
            referenceConverter: .init(algorithmicDelaySeconds: 0.005),
            referenceToMicrophoneOffsetSeconds: 0.007,
            editListOffsetSeconds: 0.011)
        let result = MeetingReferenceSynchronizer(configuration: config).synchronize(
            microphone: (0..<5).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) },
            reference: (0..<5).map { ref($0, pts: Double($0) * 0.01) })
        guard let frame = result.frames.first(where: { $0.lagSeconds != nil }) else { return XCTFail("expected overlap") }
        XCTAssertEqual(frame.timelines.microphoneSourceTime ?? .nan, 0.01, accuracy: 0.000001)
        XCTAssertEqual(frame.timelines.referencePTSTime ?? .nan, 0, accuracy: 0.000001)
        XCTAssertEqual(frame.lagSeconds ?? .nan, -0.016, accuracy: 0.000001)
    }

    func testSynthesizedTimingMakesLagUnknown() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0), mic(1, start: 160)],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01)]
        )

        XCTAssertEqual(result.frames.count, 2)
        XCTAssertTrue(result.frames.allSatisfy { $0.lagSeconds == nil })
        XCTAssertTrue(result.frames.allSatisfy { $0.unknownReasons.contains(.captureTimingSynthesized) })
    }

    func testFrameTimelinesCarryMicrophoneSampleAndHostTimes() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 8_000, host: 42), mic(1, start: 8_160, host: 42.01)],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01)]
        )

        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.frames[0].timelines.microphoneSampleTime, 8_000)
        XCTAssertEqual(result.frames[0].timelines.microphoneHostTime ?? .nan, 42, accuracy: 0.000001)
        XCTAssertEqual(result.frames[1].timelines.microphoneSampleTime, 8_160)
        XCTAssertEqual(result.frames[1].timelines.microphoneHostTime ?? .nan, 42.01, accuracy: 0.000001)
    }

    func testSequenceGapWithContiguousSampleTimesCreatesBoundaryWithoutGap() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1), mic(2, start: 160, host: 1.01)],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01)]
        )

        XCTAssertEqual(result.frames.count, 2)
        XCTAssertFalse(result.frames[1].unknownReasons.contains(.captureGap))
        XCTAssertTrue(result.frames[1].captureValidMask.allSatisfy { $0 })
        XCTAssertEqual(result.frames[1].epochID, 1)
        XCTAssertTrue(result.frames[1].resynchronizationBoundary)
    }

    func testLongReferencePTSDiscontinuityIsMaskedFrozenAndResynchronized() {
        let frameCount = 1_400
        let gapIndex = 700
        let gapSeconds = 0.002
        let configuration = MeetingReferenceSynchronizerConfiguration(
            referenceScope: .authorizedFullMix,
            referenceCompleteness: .measuredComplete
        )
        let microphone = (0..<frameCount).map {
            mic($0, start: Int64($0 * 160), host: Double($0) * 0.01,
                value: Float(($0 % 13) + 1))
        }
        let reference = (0..<frameCount).map { index in
            ref(index, pts: Double(index) * 0.01 + (index >= gapIndex ? gapSeconds : 0),
                value: Float((index % 17) + 1))
        }
        let synchronizer = MeetingReferenceSynchronizer(configuration: configuration)

        let result = synchronizer.synchronize(microphone: microphone, reference: reference)
        let replay = synchronizer.synchronize(microphone: microphone, reference: reference)

        XCTAssertEqual(result, replay)
        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.frames.count, frameCount + 1)
        XCTAssertEqual(result.diagnostics.epochCount, 2)

        let gapFrames = result.frames.filter { $0.unknownReasons.contains(.referenceGap) }
        XCTAssertEqual(gapFrames.count, 1)
        guard let gapFrame = gapFrames.first else { return }
        XCTAssertEqual(gapFrame.index, gapIndex)
        XCTAssertEqual(gapFrame.renderValidMask.filter { !$0 }.count, 32)
        XCTAssertTrue(gapFrame.captureValidMask.allSatisfy { $0 })
        XCTAssertTrue(gapFrame.adaptationFrozen)
        XCTAssertTrue(gapFrame.resynchronizationBoundary)
        XCTAssertTrue(zip(gapFrame.renderSamples, gapFrame.renderValidMask).allSatisfy {
            $0.1 || $0.0 == 0
        })

        let resumed = result.frames[gapIndex + 1]
        XCTAssertEqual(resumed.epochID, 1)
        XCTAssertTrue(resumed.renderValidMask.allSatisfy { $0 })
        XCTAssertFalse(resumed.adaptationFrozen)
        XCTAssertFalse(resumed.unknownReasons.contains(.referenceGap))
    }

    func testInvalidReferencePTSAndRateCreateReferenceGapEpoch() {
        let invalidPTS = MeetingReferencePCMFrame(sequenceNumber: 1, presentationTime: .nan,
            sampleRate: sampleRate, samples: [Float](repeating: 2, count: 160))
        let ptsResult = MeetingReferenceSynchronizer().synchronize(
            microphone: (0..<3).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) },
            reference: [ref(0, pts: 0), invalidPTS, ref(2, pts: 0.02)]
        )
        XCTAssertTrue(ptsResult.frames.contains { $0.unknownReasons.contains(.referenceGap) })
        XCTAssertGreaterThan(ptsResult.diagnostics.epochCount, 1)

        let invalidRate = MeetingReferencePCMFrame(sequenceNumber: 1, presentationTime: 0.01,
            sampleRate: 0, samples: [Float](repeating: 2, count: 160))
        let rateResult = MeetingReferenceSynchronizer().synchronize(
            microphone: (0..<3).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) },
            reference: [ref(0, pts: 0), invalidRate, ref(2, pts: 0.02)]
        )
        XCTAssertTrue(rateResult.frames.contains { $0.unknownReasons.contains(.referenceGap) })
        XCTAssertGreaterThan(rateResult.diagnostics.epochCount, 1)
    }

    func testRateChangePreservesReferenceSourcePTSInTimelines() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1), mic(1, start: 160, host: 1.01)],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01, count: 80, rate: 8_000)]
        )

        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.frames[1].timelines.referencePTSTime ?? .nan, 0.01, accuracy: 0.000001)
    }

    func testArrivalOrderWinsAndLateFramesCannotOverwriteAcceptedAudio() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [
                mic(1, start: 160, host: 1.01, value: 11),
                mic(0, start: 0, host: 1.00, value: 22),
                mic(1, start: 160, host: 1.02, value: 33),
                mic(2, start: 320, host: 1.03, value: 44)
            ],
            reference: (0..<3).map { ref($0, pts: Double($0) * 0.01) }
        )

        XCTAssertEqual(result.diagnostics.duplicateOrLateFrameCount, 2)
        XCTAssertEqual(result.diagnostics.droppedFrameCount, 2)
        XCTAssertEqual(result.frames.prefix(2).map { $0.captureSamples[0] }, [11, 44])
        XCTAssertFalse(result.frames[0].unknownReasons.contains(.captureGap))
    }

    func testRejectedSequenceIsConsumedWithoutDoubleEpochOrGap() {
        let invalid = MeetingMicrophonePCMFrame(
            sequenceNumber: 1, sampleTime: 160, hostTime: 1.01, sampleRate: sampleRate,
            samples: [Float.nan] + Array(repeating: 1, count: 159)
        )
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1), invalid, mic(2, start: 320, host: 1.02)],
            reference: (0..<3).map { ref($0, pts: Double($0) * 0.01) }
        )
        let micOnly = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1), invalid, mic(2, start: 320, host: 1.02)],
            reference: []
        )
        let refOnly = MeetingReferenceSynchronizer().synchronize(
            microphone: [], reference: (0..<3).map { ref($0, pts: Double($0) * 0.01) }
        )

        XCTAssertEqual(result.diagnostics.nonFiniteSampleCount, 1)
        XCTAssertEqual(
            result.diagnostics.epochCount,
            2,
            "epochIDs=\(result.frames.map(\.epochID)) micOnly=\(micOnly.diagnostics.epochCount) refOnly=\(refOnly.diagnostics.epochCount) reasons=\(result.frames.map(\.unknownReasons))"
        )
        XCTAssertEqual(result.frames.filter { $0.unknownReasons.contains(.captureGap) }.count, 1)
    }

    func testInvalidFirstMicrophoneFrameDoesNotBecomeTheSourceOrigin() {
        let invalid = MeetingMicrophonePCMFrame(
            sequenceNumber: 0, sampleTime: 8_000, hostTime: 40, sampleRate: 0,
            samples: [Float](repeating: 1, count: 160)
        )
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [invalid, mic(1, start: 8_160, host: 40.01)],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01)]
        )

        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.diagnostics.droppedFrameCount, 1)
        XCTAssertEqual(result.frames.first?.timelines.microphoneSampleTime, 8_160)
        XCTAssertTrue(result.frames.contains { $0.captureValidMask.contains(true) })
    }

    func testReferenceDriftScalesSegmentPlacementAndDuration() {
        let count = 10
        let sourceFrameSamples = 1_600
        let config = MeetingReferenceSynchronizerConfiguration(
            referenceClockDriftPPM: 5_000, maximumClockDriftPPM: 10_000,
            referenceScope: .authorizedFullMix, referenceCompleteness: .measuredComplete
        )
        let result = MeetingReferenceSynchronizer(configuration: config).synchronize(
            microphone: (0..<count).map {
                mic($0, start: Int64($0 * sourceFrameSamples), host: Double($0) * 0.1, count: sourceFrameSamples)
            },
            reference: (0..<count).map {
                ref($0, pts: Double($0) * 0.1, count: sourceFrameSamples)
            }
        )

        XCTAssertEqual(result.frames.count, 101)
        XCTAssertTrue(result.frames.dropLast().allSatisfy { $0.renderValidMask.contains(true) })
        XCTAssertEqual(result.frames[10].timelines.referencePTSTime ?? .nan, 0.1, accuracy: 0.002)
    }

    func testLagKeepsCodecPrimingAndAbsoluteReferencePTSCoordinates() {
        let config = MeetingReferenceSynchronizerConfiguration(
            referenceConverter: .init(algorithmicDelaySeconds: 0.004),
            referenceToMicrophoneOffsetSeconds: 0.007,
            referenceScope: .authorizedFullMix,
            referenceCompleteness: .measuredComplete,
            codecPrimingSamples: 32,
            editListOffsetSeconds: 0.01
        )
        let result = MeetingReferenceSynchronizer(configuration: config).synchronize(
            microphone: (0..<5).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) },
            reference: (0..<5).map { ref($0, pts: Double($0) * 0.01) }
        )

        guard let frame = result.frames.first(where: { $0.lagSeconds != nil }) else {
            return XCTFail("expected an overlapping frame")
        }
        XCTAssertEqual(frame.timelines.referencePTSTime ?? .nan, 0.002, accuracy: 0.001)
        // The 2 ms priming shift is retained in the source coordinate and is not removed by
        // subtracting the first reference segment origin before applying the affine mapping.
        XCTAssertEqual(frame.lagSeconds ?? .nan, -0.015, accuracy: 0.001)
    }

    func testLagIsInvariantToIndependentAbsoluteClockOrigins() {
        let config = MeetingReferenceSynchronizerConfiguration(
            microphoneConverter: .init(algorithmicDelaySeconds: 0.003),
            referenceConverter: .init(algorithmicDelaySeconds: 0.004),
            referenceToMicrophoneOffsetSeconds: 0.007,
            referenceScope: .authorizedFullMix,
            referenceCompleteness: .measuredComplete,
            codecPrimingSamples: 32,
            editListOffsetSeconds: 0.01
        )
        let synchronizer = MeetingReferenceSynchronizer(configuration: config)
        let relative = synchronizer.synchronize(
            microphone: (0..<5).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) },
            reference: (0..<5).map { ref($0, pts: Double($0) * 0.01) }
        )
        let offset = synchronizer.synchronize(
            microphone: (0..<5).map { mic($0, start: 8_000 + Int64($0 * 160), host: Double($0) * 0.01) },
            reference: (0..<5).map { ref($0, pts: 1_234 + Double($0) * 0.01) }
        )

        let relativeLag = relative.frames.compactMap(\.lagSeconds).first
        let offsetLag = offset.frames.compactMap(\.lagSeconds).first
        XCTAssertEqual(relativeLag ?? .nan, offsetLag ?? .nan, accuracy: 0.000001)
        XCTAssertEqual(offset.frames.compactMap { $0.timelines.referencePTSTime }.first ?? .nan,
                       1_234.002, accuracy: 0.001)
    }

    func testForwardSequenceWithNonMonotonicMicrophoneSampleTimeIsDropped() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [
                mic(0, start: 0, value: 10),
                mic(1, start: 80, value: 20), // overlaps the accepted source cursor
                mic(2, start: 160, value: 30)
            ],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01)]
        )

        XCTAssertEqual(result.diagnostics.droppedFrameCount, 1)
        XCTAssertEqual(result.diagnostics.duplicateOrLateFrameCount, 1)
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.frames.map { $0.captureSamples[0] }, [10, 30])
        XCTAssertTrue(result.frames.allSatisfy { $0.captureValidMask.allSatisfy { $0 } })
        XCTAssertFalse(result.frames.contains { $0.unknownReasons.contains(.captureGap) })
    }

    func testForwardSequenceWithNonMonotonicReferencePTSIsDropped() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0), mic(1, start: 160)],
            reference: [
                ref(0, pts: 0, value: 10),
                ref(1, pts: 0.005, value: 20), // overlaps the accepted reference cursor
                ref(2, pts: 0.01, value: 30)
            ]
        )

        XCTAssertEqual(result.diagnostics.droppedFrameCount, 1)
        XCTAssertEqual(result.diagnostics.duplicateOrLateFrameCount, 1)
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.frames.map { $0.renderSamples[0] }, [10, 30])
        XCTAssertTrue(result.frames.allSatisfy { $0.renderValidMask.allSatisfy { $0 } })
        XCTAssertFalse(result.frames.contains { $0.unknownReasons.contains(.referenceGap) })
    }

    func testContiguousRouteRateAndDiscontinuityResetsDoNotCreateGaps() {
        let changedMic = MeetingMicrophonePCMFrame(
            sequenceNumber: 1, sampleTime: 160, hostTime: 1.01, sampleRate: sampleRate,
            samples: [Float](repeating: 2, count: 160), routeIdentifier: "route-b", discontinuity: true)
        let changedRef = ref(1, pts: 0.01, count: 80, rate: 8_000, discontinuity: true)
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1), changedMic],
            reference: [ref(0, pts: 0), changedRef]
        )

        XCTAssertEqual(result.frames.count, 2)
        XCTAssertGreaterThan(result.diagnostics.epochCount, 1)
        XCTAssertTrue(result.frames[1].captureValidMask.allSatisfy { $0 })
        XCTAssertTrue(result.frames[1].renderValidMask.allSatisfy { $0 })
        XCTAssertFalse(result.frames[1].unknownReasons.contains(.captureGap))
        XCTAssertFalse(result.frames[1].unknownReasons.contains(.referenceGap))
    }

    func testSharedResetEventAcrossTracksAdvancesEpochOnlyOnce() {
        let changedMic = mic(1, start: 160, host: 1.01, route: "route-b", discontinuity: true)
        let changedRef = ref(1, pts: 0.01, discontinuity: true)
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1), changedMic],
            reference: [ref(0, pts: 0), changedRef]
        )

        XCTAssertEqual(result.diagnostics.epochCount, 2)
        XCTAssertEqual(result.frames.map(\.epochID), [0, 1])
    }

    func testExtremeInt64SampleTimesAreDroppedWithoutOverflowTrap() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [
                mic(0, start: .min, host: 1),
                mic(1, start: .max, host: 1.01)
            ],
            reference: [ref(0, pts: 0), ref(1, pts: 0.01)]
        )

        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.diagnostics.droppedFrameCount, 1)
        XCTAssertEqual(result.diagnostics.duplicateOrLateFrameCount, 1)
    }

    func testPreOriginInvalidFramesDoNotCreateFalseOverlapGaps() {
        let invalidMic = MeetingMicrophonePCMFrame(
            sequenceNumber: 0, sampleTime: 8_000, hostTime: 40, sampleRate: 0,
            samples: [Float](repeating: 1, count: 160))
        let invalidReference = MeetingReferencePCMFrame(
            sequenceNumber: 0, presentationTime: .nan, sampleRate: sampleRate,
            samples: [Float](repeating: 2, count: 160))
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [invalidMic, mic(1, start: 8_160, host: 40.01)],
            reference: [invalidReference, ref(1, pts: 0.01)]
        )

        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.diagnostics.droppedFrameCount, 2)
        XCTAssertTrue(result.frames[0].captureValidMask.allSatisfy { $0 })
        XCTAssertTrue(result.frames[0].renderValidMask.allSatisfy { $0 })
        XCTAssertFalse(result.frames[0].unknownReasons.contains(.captureGap))
        XCTAssertFalse(result.frames[0].unknownReasons.contains(.referenceGap))
    }

    func testMidstreamEmptyBlockIsOneUnknownGapAndAllEmptyInputIsDropped() {
        let emptyMic = MeetingMicrophonePCMFrame(
            sequenceNumber: 1, sampleTime: 160, hostTime: 1.01, sampleRate: sampleRate, samples: [])
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1), emptyMic, mic(2, start: 320, host: 1.02)],
            reference: (0..<3).map { ref($0, pts: Double($0) * 0.01) }
        )
        XCTAssertEqual(result.diagnostics.droppedFrameCount, 1)
        XCTAssertEqual(result.diagnostics.epochCount, 2)
        XCTAssertTrue(result.frames[1].unknownReasons.contains(.captureGap))
        XCTAssertTrue(result.frames[2].captureValidMask.allSatisfy { $0 })

        let allEmpty = MeetingReferenceSynchronizer().synchronize(
            microphone: [emptyMic], reference: [MeetingReferencePCMFrame(
                sequenceNumber: 0, presentationTime: 0, sampleRate: sampleRate, samples: [])])
        XCTAssertEqual(allEmpty.diagnostics.droppedFrameCount, 2)
        XCTAssertTrue(allEmpty.frames.isEmpty)
    }

    func testOutputBudgetFailureRetainsTimingDiagnostics() {
        let config = MeetingReferenceSynchronizerConfiguration(maximumOutputFrameCount: 1)
        let result = MeetingReferenceSynchronizer(configuration: config).synchronize(
            microphone: (0..<3).map { mic($0, start: Int64($0 * 160), host: nil) },
            reference: (0..<3).map { ref($0, pts: Double($0) * 0.01) }
        )

        XCTAssertTrue(result.failedOpen)
        XCTAssertTrue(result.diagnostics.boundedResourceFailure)
        XCTAssertEqual(result.diagnostics.synthesizedMicrophoneFrameCount, 3)
    }

    func testFirstFrameDiscontinuityIsInitialMetadataNotAnEpochTransition() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [mic(0, start: 0, host: 1, discontinuity: true), mic(1, start: 160, host: 1.01)],
            reference: [ref(0, pts: 0, discontinuity: true), ref(1, pts: 0.01)]
        )

        XCTAssertEqual(result.diagnostics.epochCount, 1)
        XCTAssertEqual(result.frames.map(\.epochID), [0, 0])
    }

    func test44100HzContiguousShortSegmentsHaveNoResamplingSeamHoles() {
        let result = MeetingReferenceSynchronizer().synchronize(
            // 100 samples at 44.1 kHz maps to 36.28 analysis samples. Independent
            // per-segment rounding would leave alternating seam holes/overlaps.
            microphone: (0..<10).map {
                MeetingMicrophonePCMFrame(sequenceNumber: $0, sampleTime: Int64($0 * 100),
                    hostTime: Double($0 * 100) / 44_100, sampleRate: 44_100,
                    samples: [Float](repeating: 1, count: 100)
                )
            },
            reference: (0..<10).map {
                MeetingReferencePCMFrame(sequenceNumber: $0, presentationTime: Double($0 * 100) / 44_100,
                    sampleRate: 44_100, samples: [Float](repeating: 2, count: 100)
                )
            }
        )

        XCTAssertEqual(result.frames.count, 3)
        XCTAssertTrue(result.frames.dropLast().allSatisfy { $0.captureValidMask.allSatisfy { $0 } })
        XCTAssertTrue(result.frames.dropLast().allSatisfy { $0.renderValidMask.allSatisfy { $0 } })
        XCTAssertFalse(result.frames.contains { $0.unknownReasons.contains(.captureGap) })
        XCTAssertFalse(result.frames.contains { $0.unknownReasons.contains(.referenceGap) })
    }

    func testFiniteExtremeStereoSamplesRemainFiniteAfterDownmix() {
        let extreme = MeetingMicrophonePCMFrame(
            sequenceNumber: 0, sampleTime: 0, hostTime: 1, sampleRate: sampleRate,
            channelCount: 2, samples: Array(repeating: .greatestFiniteMagnitude, count: 320))
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: [extreme], reference: [ref(0, pts: 0)])

        XCTAssertEqual(result.diagnostics.nonFiniteSampleCount, 0)
        XCTAssertTrue(result.frames[0].captureValidMask.allSatisfy { $0 })
        XCTAssertTrue(result.frames[0].captureSamples.allSatisfy { $0.isFinite })
    }

    func testStage05DelayContractRequiresRenderBeforeCaptureAndOneAdaptiveOwner() {
        let contract = MeetingAECDelayContract(renderLeadSeconds: 0.020, boundedEngineHintSeconds: 0.100)
        let valid = [
            MeetingAECDelayContractEvent(frameIndex: 0, kind: .render),
            MeetingAECDelayContractEvent(frameIndex: 0, kind: .capture),
            MeetingAECDelayContractEvent(frameIndex: 1, kind: .render),
            MeetingAECDelayContractEvent(frameIndex: 1, kind: .capture)
        ]
        XCTAssertTrue(contract.isValid)
        XCTAssertTrue(contract.validates(events: valid))
        XCTAssertFalse(contract.validates(events: Array(valid.reversed())))
    }

    func testStage05DelayContractAcceptsSynchronizerEpochAndMaskOutput() {
        let result = MeetingReferenceSynchronizer().synchronize(
            microphone: (0..<2).map { mic($0, start: Int64($0 * 160), host: Double($0) * 0.01) },
            reference: (0..<2).map { ref($0, pts: Double($0) * 0.01) })
        let contract = MeetingAECDelayContract(renderLeadSeconds: 0.010)
        XCTAssertTrue(contract.validates(synchronizedResult: result))
        XCTAssertTrue(result.frames.allSatisfy { $0.epochID >= 0 && $0.renderValidMask.count == $0.captureValidMask.count })
    }

    func testStage05ManifestRejectsCompressedUnsafeAndWrongTopologyArtifacts() {
        let artifact = MeetingSignalDomainGateManifest.Artifact(
            role: "render", relativePath: "../render.m4a", sha256: String(repeating: "a", count: 64),
            codec: "aac", lossless: false, sampleRateHz: 16_000, channelCount: 1, durationSeconds: 1)
        let capture = MeetingSignalDomainGateManifest.Artifact(
            role: "capture", relativePath: "capture.wav", sha256: String(repeating: "b", count: 64),
            codec: "pcm_s16le", lossless: true, sampleRateHz: 16_000, channelCount: 1, durationSeconds: 1)
        let manifest = MeetingSignalDomainGateManifest(
            topology: .vpio, route: .externalDevice, referenceScope: .unknown,
            referenceCompletenessMeasured: false, consentConfirmed: false, artifacts: [artifact, capture])
        let reasons = manifest.validationReasons()
        XCTAssertTrue(reasons.contains(.unsupportedTopology))
        XCTAssertTrue(reasons.contains(.nonLossless))
        XCTAssertTrue(reasons.contains(.unsupportedCodec))
        XCTAssertTrue(reasons.contains(.invalidManifest))
        XCTAssertTrue(reasons.contains(.missingConsent))
    }

    func testStage05MetadataOnlyInputIsExplicitlyUnscoredAndRetainsNoContent() {
        let artifact = { (role: String, path: String) in MeetingSignalDomainGateManifest.Artifact(
            role: role, relativePath: path, sha256: String(repeating: "a", count: 64),
            codec: "pcm_s16le", lossless: true, sampleRateHz: 16_000,
            channelCount: 1, durationSeconds: 1) }
        let manifest = MeetingSignalDomainGateManifest(
            topology: .pairedScreenCaptureKit, route: .builtInSpeakerMicrophone,
            referenceScope: .selectedApplication, referenceCompletenessMeasured: true,
            consentConfirmed: true,
            artifacts: [artifact("render", "r.wav"), artifact("capture", "c.wav")])
        let session = MeetingSignalDomainGateSession(ordinal: 7, renderBlocks: [], captureBlocks: [])
        let report = MeetingSignalDomainGate.evaluate(manifest: manifest, sessions: [session])
        XCTAssertEqual(report.outcome, .unscored)
        XCTAssertEqual(report.eligibleSessionCount, 0)
        XCTAssertFalse(report.rawPCMRetained)
        XCTAssertFalse(report.transcriptRetained)
        XCTAssertFalse(report.pathsRetained)
        XCTAssertTrue(report.excludedSessions.first?.reasons.contains(.metadataOnly) == true)
    }

    func testStage05RejectsGapOverlapDuplicateOrdinalAndInvalidThresholds() {
        let artifact = { (role: String, path: String) in MeetingSignalDomainGateManifest.Artifact(
            role: role, relativePath: path, sha256: String(repeating: "a", count: 64),
            codec: "pcm_s16le", lossless: true, sampleRateHz: 16_000, channelCount: 1, durationSeconds: 2) }
        let manifest = MeetingSignalDomainGateManifest(
            topology: .pairedScreenCaptureKit, route: .builtInSpeakerMicrophone,
            referenceScope: .selectedApplication, referenceCompletenessMeasured: true,
            consentConfirmed: true, artifacts: [artifact("render", "r.wav"), artifact("capture", "c.wav")])
        let samples = [Float](repeating: 0.1, count: 16_000)
        let first = MeetingSignalDomainGateTrackBlock(presentationSeconds: 0, durationSeconds: 1, arrivalSeconds: 0, samples: samples)
        let gap = MeetingSignalDomainGateTrackBlock(presentationSeconds: 2, durationSeconds: 1, arrivalSeconds: 2, samples: samples)
        let overlap = MeetingSignalDomainGateTrackBlock(presentationSeconds: 2.5, durationSeconds: 1, arrivalSeconds: 2.5, samples: samples)
        let session = MeetingSignalDomainGateSession(ordinal: 1, renderBlocks: [first, gap, overlap], captureBlocks: [first, gap, overlap])
        let thresholds = MeetingSignalDomainGateThresholds(minimumExposureSeconds: 0.1)
        let report = MeetingSignalDomainGate.evaluate(manifest: manifest, sessions: [session, session], thresholds: thresholds)
        XCTAssertTrue(report.reasonCounts[MeetingSignalDomainGateReason.gapDetected.rawValue] ?? 0 > 0)
        XCTAssertTrue(report.reasonCounts[MeetingSignalDomainGateReason.overlappingBlocks.rawValue] ?? 0 > 0)
        XCTAssertTrue(report.reasonCounts[MeetingSignalDomainGateReason.duplicateOrdinal.rawValue] ?? 0 > 0)

        let invalid = MeetingSignalDomainGateThresholds(maximumSearchDelaySeconds: .nan)
        let invalidReport = MeetingSignalDomainGate.evaluate(manifest: manifest, sessions: [], thresholds: invalid)
        XCTAssertTrue(invalidReport.reasonCounts[MeetingSignalDomainGateReason.invalidThresholds.rawValue] ?? 0 > 0)
    }

    func testStage05MissingArrivalMetadataIsNotTreatedAsMeasuredJitter() {
        let artifact = { (role: String, path: String) in MeetingSignalDomainGateManifest.Artifact(
            role: role, relativePath: path, sha256: String(repeating: "a", count: 64),
            codec: "pcm_s16le", lossless: true, sampleRateHz: 16_000, channelCount: 1, durationSeconds: 2) }
        let manifest = MeetingSignalDomainGateManifest(
            topology: .pairedScreenCaptureKit, route: .builtInSpeakerMicrophone,
            referenceScope: .selectedApplication, referenceCompletenessMeasured: true,
            consentConfirmed: true, artifacts: [artifact("render", "r.wav"), artifact("capture", "c.wav")])
        let block = MeetingSignalDomainGateTrackBlock(presentationSeconds: 0, durationSeconds: 1, samples: [0.1, 0.2])
        let session = MeetingSignalDomainGateSession(ordinal: 2, renderBlocks: [block], captureBlocks: [block])
        let report = MeetingSignalDomainGate.evaluate(manifest: manifest, sessions: [session])
        XCTAssertTrue(report.reasonCounts[MeetingSignalDomainGateReason.missingArrivalMetadata.rawValue] ?? 0 > 0)
        XCTAssertNil(report.metrics.first?.deliveryJitterP50Seconds)
    }

    func testStage05DeterministicMultibandFIRFixtureCanPassSignalGate() {
        let sampleRate = 16_000.0
        var state: UInt32 = 0x1234_5678
        let samples = (0..<16_000).map { index -> Float in
            let t = Double(index) / sampleRate
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(state) / Float(UInt32.max) - 0.5) * 0.01
            return Float(0.08 * (sin(2 * .pi * 250 * t) + sin(2 * .pi * 1_000 * t) + sin(2 * .pi * 4_000 * t)) / 3) + noise
        }
        let blocks = stride(from: 0, to: 16_000, by: 4_000).map { start in
            MeetingSignalDomainGateTrackBlock(presentationSeconds: Double(start) / sampleRate,
                durationSeconds: 0.25, arrivalSeconds: Double(start) / sampleRate,
                samples: Array(samples[start..<(start + 4_000)]))
        }
        let artifact = { (role: String, path: String) in MeetingSignalDomainGateManifest.Artifact(
            role: role, relativePath: path, sha256: String(repeating: "a", count: 64),
            codec: "pcm_s16le", lossless: true, sampleRateHz: sampleRate, channelCount: 1, durationSeconds: 1) }
        let manifest = MeetingSignalDomainGateManifest(
            topology: .pairedScreenCaptureKit, route: .builtInSpeakerMicrophone,
            referenceScope: .selectedApplication, referenceCompletenessMeasured: true,
            consentConfirmed: true, artifacts: [artifact("render", "r.wav"), artifact("capture", "c.wav")])
        let session = MeetingSignalDomainGateSession(ordinal: 3, renderBlocks: blocks, captureBlocks: blocks)
        let report = MeetingSignalDomainGate.evaluate(manifest: manifest, sessions: [session],
            thresholds: .init(maximumSearchDelaySeconds: 0.05, safetyMarginSeconds: 0.01,
                              minimumBandCoherence: 0.05,
                              maximumHeldOutLinearResidualFraction: 0.25))
        XCTAssertEqual(report.outcome, .proceedToCandidate)
        XCTAssertEqual(report.metrics.first?.sessionOrdinal, 3)
        XCTAssertNotNil(report.metrics.first?.signedDelayP50Seconds)
        XCTAssertNotNil(report.metrics.first?.signedDelayP95Seconds)
        XCTAssertNotNil(report.metrics.first?.signedDelayP99Seconds)
        XCTAssertNotNil(report.metrics.first?.driftP50PPM)
        XCTAssertNotNil(report.metrics.first?.driftP95PPM)
        XCTAssertNotNil(report.metrics.first?.driftP99PPM)
        XCTAssertEqual(report.metrics.first?.bandCoherence.count, 3)
        XCTAssertNotNil(report.metrics.first?.pathStabilityFraction)
        XCTAssertNotNil(report.metrics.first?.clippingFraction)
        XCTAssertNotNil(report.metrics.first?.heldOutLinearResidualFraction)
        XCTAssertGreaterThanOrEqual(report.metrics.first?.delayObservationCount ?? 0, 3)
    }

    func testStage05TimeVaryingFIRFixtureFailsLearnabilityGate() {
        let sampleRate = 16_000.0
        let render = (0..<16_000).map { index in Float(sin(2 * .pi * 1_000 * Double(index) / sampleRate) * 0.1) }
        let capture = render.enumerated().map { index, value in index >= 12_000 ? value * 0.05 : value }
        let blocks = stride(from: 0, to: 16_000, by: 4_000).map { start in
            MeetingSignalDomainGateTrackBlock(presentationSeconds: Double(start) / sampleRate,
                durationSeconds: 0.25, arrivalSeconds: Double(start) / sampleRate,
                samples: Array(render[start..<(start + 4_000)]))
        }
        let captureBlocks = stride(from: 0, to: 16_000, by: 4_000).map { start in
            MeetingSignalDomainGateTrackBlock(presentationSeconds: Double(start) / sampleRate,
                durationSeconds: 0.25, arrivalSeconds: Double(start) / sampleRate,
                samples: Array(capture[start..<(start + 4_000)]))
        }
        let artifact = { (role: String, path: String) in MeetingSignalDomainGateManifest.Artifact(
            role: role, relativePath: path, sha256: String(repeating: "a", count: 64),
            codec: "pcm_s16le", lossless: true, sampleRateHz: sampleRate, channelCount: 1, durationSeconds: 1) }
        let manifest = MeetingSignalDomainGateManifest(
            topology: .pairedScreenCaptureKit, route: .builtInSpeakerMicrophone,
            referenceScope: .selectedApplication, referenceCompletenessMeasured: true,
            consentConfirmed: true, artifacts: [artifact("render", "r.wav"), artifact("capture", "c.wav")])
        let session = MeetingSignalDomainGateSession(ordinal: 4, renderBlocks: blocks, captureBlocks: captureBlocks)
        let report = MeetingSignalDomainGate.evaluate(manifest: manifest, sessions: [session],
            thresholds: .init(maximumSearchDelaySeconds: 0.05, safetyMarginSeconds: 0.01,
                              minimumBandCoherence: 0,
                              maximumHeldOutLinearResidualFraction: 0.10))
        XCTAssertEqual(report.outcome, .rejected)
        XCTAssertTrue(report.metrics.isEmpty)
        XCTAssertTrue(report.reasonCounts[MeetingSignalDomainGateReason.linearPathUnlearnable.rawValue] ?? 0 > 0)
    }
}
