#if DEBUG

@testable import FluidVoice_Debug
import CoreAudio
import CoreMedia
import Darwin
import Foundation
import XCTest

/// Synthetic CMSampleBuffer factory shared by the Stage 0.5 adapter and timing-record
/// suites. Offline only: no SCStream, no browser, no audio hardware.
enum Stage05SyntheticBuffer {
    static func monoFloat32(
        pts: Double,
        frameCount: Int,
        value: Float = 0.01,
        sampleRate: Double = 48_000,
        channels: Int = 1,
        discontinuity: Bool = false
    ) -> CMSampleBuffer? {
        let bytesPerFrame = 4 * channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription) == noErr, let formatDescription else { return nil }
        let byteCount = frameCount * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return nil }
        let samples = [Float](repeating: value, count: frameCount * channels)
        guard samples.withUnsafeBytes({
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }) == noErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return nil }
        if discontinuity,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[MeetingStage05SCKFrameAdapter.discontinuityAttachmentKey] = true
        }
        return sampleBuffer
    }
}

final class MeetingStage05SCKFrameAdapterTests: XCTestCase {
    private let rate = 48_000.0
    private let blockFrames = 480 // 10 ms per callback block

    private func block(
        pts: Double, frames: Int? = nil, arrival: Double? = nil,
        value: Float = 0.5, discontinuity: Bool = false
    ) -> MeetingStage05AdapterFrame {
        let count = frames ?? blockFrames
        return MeetingStage05AdapterFrame(
            presentationSeconds: pts, durationSeconds: Double(count) / rate,
            frameCount: count, sampleRateHz: rate, arrivalSeconds: arrival,
            samples: [Float](repeating: value, count: count), discontinuity: discontinuity)
    }

    private func feedPaired(
        _ adapter: MeetingStage05SCKFrameAdapter, count: Int,
        renderGap: (at: Int, seconds: Double)? = nil,
        microphoneGap: (at: Int, seconds: Double)? = nil
    ) {
        for index in 0..<count {
            let base = Double(index) * 0.01
            let renderPTS = base + (renderGap.map { index >= $0.at ? $0.seconds : 0 } ?? 0)
            let micPTS = base + (microphoneGap.map { index >= $0.at ? $0.seconds : 0 } ?? 0)
            XCTAssertNil(adapter.appendRenderFrame(block(pts: renderPTS, value: 0.25)))
            XCTAssertNil(adapter.appendMicrophoneFrame(block(pts: micPTS, arrival: micPTS, value: 0.5)))
        }
    }

    // MARK: Contiguous baseline and mock-seam contract

    func testContiguousPairedCallbacksSynchronizeAndValidateRenderBeforeCapture() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        feedPaired(adapter, count: 10)

        let (drained, result) = adapter.synchronize()
        XCTAssertEqual(drained.renderDiagnostics, MeetingStage05AdapterTrackDiagnostics(accepted: 10))
        XCTAssertEqual(drained.microphoneDiagnostics, MeetingStage05AdapterTrackDiagnostics(accepted: 10))
        XCTAssertEqual(drained.reference.map(\.sequenceNumber), Array(0..<10))
        XCTAssertEqual(drained.microphone.map(\.sequenceNumber), Array(0..<10))
        XCTAssertEqual(drained.microphone.map(\.sampleTime), (0..<10).map { Int64($0 * 480) })
        XCTAssertEqual(drained.microphone.map(\.routeIdentifier).first, "route-a")
        XCTAssertEqual(drained.microphone.first?.hostTime, 0)

        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.frames.count, 10)
        XCTAssertTrue(result.frames.allSatisfy {
            $0.renderValidMask.allSatisfy { $0 } && $0.captureValidMask.allSatisfy { $0 }
                && !$0.adaptationFrozen && !$0.resynchronizationBoundary
        })

        let seam = MeetingStage05MockAECSeam().process(result)
        XCTAssertTrue(seam.authorized)
        XCTAssertEqual(seam.frames, result.frames)
        XCTAssertEqual(seam.processedFrameCount, 10)
        XCTAssertEqual(seam.frozenFrameCount, 0)
        XCTAssertEqual(seam.boundaryCount, 0)
        XCTAssertEqual(seam.observations.count, 10)
        XCTAssertTrue(seam.observations.allSatisfy {
            !$0.reset && !$0.adaptationFrozen && $0.renderValidCount == 160
                && $0.captureValidCount == 160
        })
        XCTAssertEqual(seam.events.count, 20)
        XCTAssertTrue(MeetingAECDelayContract(renderLeadSeconds: 0.010).validates(events: seam.events))
    }

    // MARK: Gap matrix

    private func runRenderGap(gapSeconds: Double, gapIndex: Int = 20, blocks: Int = 40)
        -> (MeetingStage05AdapterDrain, MeetingSynchronizationResult) {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        feedPaired(adapter, count: blocks, renderGap: (gapIndex, gapSeconds))
        return adapter.synchronize()
    }

    private func assertRenderGap(
        _ result: MeetingSynchronizationResult, gapIndices: Range<Int>, invalidRender: Int,
        boundaryIndex: Int, resumedIndex: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(result.failedOpen, file: file, line: line)
        XCTAssertEqual(result.diagnostics.epochCount, 2, file: file, line: line)
        let gapFrames = result.frames.filter { $0.unknownReasons.contains(.referenceGap) }
        XCTAssertEqual(gapFrames.map(\.index), Array(gapIndices), file: file, line: line)
        let invalidInsideGap = gapFrames.reduce(0) {
            $0 + $1.renderValidMask.filter { !$0 }.count
        }
        XCTAssertEqual(invalidInsideGap, invalidRender, file: file, line: line)
        XCTAssertTrue(gapFrames.allSatisfy { frame in
            frame.adaptationFrozen
                && frame.captureValidMask.allSatisfy { $0 }
                && zip(frame.renderSamples, frame.renderValidMask).allSatisfy { $0.1 || $0.0 == 0 }
        }, file: file, line: line)
        XCTAssertEqual(result.frames.filter(\.resynchronizationBoundary).map(\.index),
                       [boundaryIndex], file: file, line: line)
        XCTAssertEqual(result.frames[resumedIndex].epochID, 1, file: file, line: line)
        XCTAssertTrue(result.frames[resumedIndex].renderValidMask.allSatisfy { $0 },
                      file: file, line: line)
    }

    func testAdapterDrivenTwoMillisecondRenderJumpYieldsExactly32InvalidSamples() {
        let (drained, result) = runRenderGap(gapSeconds: 0.002)
        XCTAssertEqual(drained.renderDiagnostics.gapCount, 1)
        XCTAssertEqual(drained.renderDiagnostics.acceptedCallbackCount, 40)
        assertRenderGap(result, gapIndices: 20..<21, invalidRender: 32,
                        boundaryIndex: 20, resumedIndex: 21)

        let resumed = result.frames[21]
        XCTAssertEqual(resumed.epochID, 1)
        XCTAssertTrue(resumed.renderValidMask.allSatisfy { $0 })
        XCTAssertFalse(resumed.adaptationFrozen)
        XCTAssertFalse(resumed.unknownReasons.contains(.referenceGap))

        let seam = MeetingStage05MockAECSeam().process(result)
        XCTAssertTrue(seam.authorized)
        XCTAssertEqual(seam.frames, result.frames)
        XCTAssertEqual(seam.frozenFrameCount, result.frames.filter(\.adaptationFrozen).count)
        XCTAssertEqual(seam.frozenFrameCount, 2) // the gap hop and the unmatched tail hop
        XCTAssertEqual(seam.boundaryCount, 1)
        XCTAssertEqual(seam.observations[20].frameIndex, 20)
        XCTAssertTrue(seam.observations[20].reset)
        XCTAssertTrue(seam.observations[20].adaptationFrozen)
        XCTAssertTrue(seam.observations[20].resynchronizationBoundary)
        XCTAssertEqual(seam.observations[20].renderValidCount, 128)
        XCTAssertEqual(seam.observations[20].captureValidCount, 160)
        XCTAssertTrue(seam.observations[20].unknownReasons.contains(.referenceGap))
        XCTAssertFalse(MeetingAECDelayContract(renderLeadSeconds: 0.010).validates(events: seam.events),
                       "a frozen hop must be absent from events, so the full contract cannot validate")
        var seen: [Int: [MeetingAECDelayContractEventKind]] = [:]
        for event in seam.events { seen[event.frameIndex, default: []].append(event.kind) }
        XCTAssertTrue(seen.values.allSatisfy { $0 == [.render, .capture] })
        XCTAssertNil(seen[20])
    }

    func testRenderGapOfOneSampleFreezesWithoutInventedCoverage() {
        let (drained, result) = runRenderGap(gapSeconds: 1 / rate)
        XCTAssertEqual(drained.renderDiagnostics.gapCount, 1)
        // A sub-analysis-sample hole cannot produce invalid 16 kHz samples; the reason,
        // freeze, and boundary carry it instead of fabricated silence.
        let hop = result.frames[20]
        XCTAssertTrue(hop.unknownReasons.contains(.referenceGap))
        XCTAssertTrue(hop.adaptationFrozen)
        XCTAssertTrue(hop.resynchronizationBoundary)
        XCTAssertEqual(hop.epochID, 0)
        XCTAssertEqual(hop.renderValidMask.filter { !$0 }.count, 0)
        XCTAssertEqual(result.frames[21].epochID, 1)
    }

    func testRenderGapOfTenMillisecondsIsExactlyOneInvalidHop() {
        let (drained, result) = runRenderGap(gapSeconds: 0.010)
        XCTAssertEqual(drained.renderDiagnostics.gapCount, 1)
        assertRenderGap(result, gapIndices: 20..<21, invalidRender: 160,
                        boundaryIndex: 21, resumedIndex: 21)
        XCTAssertEqual(result.frames.count, 41)
        XCTAssertEqual(result.frames[20].renderValidMask, [Bool](repeating: false, count: 160))
        XCTAssertTrue(result.frames[21].adaptationFrozen, "the first resumed hop performs the reset")
    }

    func testRenderGapOfHundredMillisecondsSpansTenInvalidHops() {
        let (drained, result) = runRenderGap(gapSeconds: 0.100)
        XCTAssertEqual(drained.renderDiagnostics.gapCount, 1)
        assertRenderGap(result, gapIndices: 20..<30, invalidRender: 1_600,
                        boundaryIndex: 30, resumedIndex: 30)
        XCTAssertEqual(result.frames.count, 50)
        XCTAssertTrue(result.frames[20..<30].allSatisfy {
            $0.renderValidMask.allSatisfy { !$0 } && $0.adaptationFrozen
        })
        XCTAssertTrue(result.frames[30].adaptationFrozen, "the first resumed hop performs the reset")
        XCTAssertTrue(result.frames[30].renderValidMask.allSatisfy { $0 })
        XCTAssertFalse(result.frames[31].adaptationFrozen)
    }

    func testMicrophoneGapOfTwoMillisecondsYieldsExactly32InvalidCaptureSamples() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        feedPaired(adapter, count: 40, microphoneGap: (20, 0.002))
        let (drained, result) = adapter.synchronize()

        XCTAssertEqual(drained.microphoneDiagnostics.gapCount, 1)
        XCTAssertFalse(result.failedOpen)
        let gapFrames = result.frames.filter { $0.unknownReasons.contains(.captureGap) }
        let internalGapFrames = gapFrames.filter { $0.index == 20 }
        XCTAssertEqual(internalGapFrames.reduce(0) {
            $0 + $1.captureValidMask.filter { !$0 }.count
        }, 32)
        let hop = result.frames[20]
        XCTAssertTrue(hop.unknownReasons.contains(.captureGap))
        XCTAssertTrue(hop.adaptationFrozen)
        XCTAssertTrue(hop.renderValidMask.allSatisfy { $0 })
        let seam = MeetingStage05MockAECSeam().process(result)
        XCTAssertEqual(seam.frozenFrameCount, result.frames.filter(\.adaptationFrozen).count)
        XCTAssertEqual(seam.frozenFrameCount, 2) // the gap hop and the unmatched tail hop
        XCTAssertEqual(seam.boundaryCount, 1) // epoch change is handled before processing
        XCTAssertEqual(seam.frames, result.frames)
    }

    func testRepeatedGapsSeparatedByValidIsland() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        for index in 0..<60 {
            let shift = (index >= 20 ? 0.010 : 0) + (index >= 40 ? 0.020 : 0)
            let pts = Double(index) * 0.01 + shift
            XCTAssertNil(adapter.appendRenderFrame(block(pts: pts, value: 0.25)))
            XCTAssertNil(adapter.appendMicrophoneFrame(block(pts: Double(index) * 0.01 + shift,
                                                             arrival: Double(index) * 0.01 + shift)))
        }
        let (drained, result) = adapter.synchronize()

        XCTAssertEqual(drained.renderDiagnostics.gapCount, 2)
        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.diagnostics.epochCount, 3)
        XCTAssertEqual(result.frames.reduce(0) { $0 + $1.renderValidMask.filter { !$0 }.count }, 160 + 320)
        XCTAssertEqual(result.frames.filter(\.resynchronizationBoundary).map(\.index), [21, 43])
        // The island between the gaps is fully valid and unfrozen.
        XCTAssertTrue(result.frames[22..<41].allSatisfy {
            $0.renderValidMask.allSatisfy { $0 } && $0.captureValidMask.allSatisfy { $0 }
                && !$0.adaptationFrozen && !$0.resynchronizationBoundary
        })
        let seam = MeetingStage05MockAECSeam().process(result)
        XCTAssertEqual(seam.frozenFrameCount, 5) // gap hops 20, 41...42 plus resets 21 and 43
        XCTAssertEqual(seam.boundaryCount, 2)
        XCTAssertEqual(seam.frames, result.frames)
    }

    // MARK: Overlaps and backward timestamps

    private func overlapScenario(
        overlappedPTS: Double
    ) -> (MeetingStage05AdapterDrain, MeetingSynchronizationResult, MeetingSynchronizationResult) {
        let baseline = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let variant = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        for index in 0..<10 {
            let value = Float(index + 1) / 20
            XCTAssertNil(baseline.appendRenderFrame(
                block(pts: Double(index) * 0.01, value: value)))
            XCTAssertNil(baseline.appendMicrophoneFrame(
                block(pts: Double(index) * 0.01, arrival: Double(index) * 0.01)))
            let pts = index == 5 ? overlappedPTS : Double(index) * 0.01
            XCTAssertNil(variant.appendRenderFrame(block(pts: pts, value: value)))
            XCTAssertNil(variant.appendMicrophoneFrame(block(pts: Double(index) * 0.01,
                                                             arrival: Double(index) * 0.01)))
        }
        let baselineResult = baseline.synchronize().1
        let (drained, result) = variant.synchronize()
        return (drained, result, baselineResult)
    }

    private func assertOverlapDropsLateBlock(
        _ drained: MeetingStage05AdapterDrain, _ result: MeetingSynchronizationResult,
        _ baseline: MeetingSynchronizationResult, expectBackward: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(drained.renderDiagnostics.overlapCount, 1, file: file, line: line)
        XCTAssertEqual(drained.renderDiagnostics.backwardCount, expectBackward ? 1 : 0, file: file, line: line)
        // The late block is preserved as a synchronizer input; first arrival wins there.
        XCTAssertEqual(drained.reference.count, 10, file: file, line: line)
        XCTAssertEqual(result.diagnostics.duplicateOrLateFrameCount, 1, file: file, line: line)
        XCTAssertFalse(result.failedOpen, file: file, line: line)
        XCTAssertEqual(result.frames.count, baseline.frames.count, file: file, line: line)
        for hop in 0..<5 {
            XCTAssertEqual(result.frames[hop].renderSamples, baseline.frames[hop].renderSamples,
                           file: file, line: line)
        }
        XCTAssertEqual(result.frames[5].renderValidMask, [Bool](repeating: false, count: 160),
                       file: file, line: line)
        for hop in 6..<10 {
            XCTAssertEqual(result.frames[hop].renderSamples, baseline.frames[hop].renderSamples,
                           file: file, line: line)
        }
    }

    func testOneSampleOverlapCannotOverwriteAcceptedSamples() {
        let (drained, result, baseline) = overlapScenario(overlappedPTS: 0.05 - 1 / rate)
        assertOverlapDropsLateBlock(drained, result, baseline, expectBackward: false)
    }

    func testHalfFrameOverlapCannotOverwriteAcceptedSamples() {
        let (drained, result, baseline) = overlapScenario(overlappedPTS: 0.045)
        assertOverlapDropsLateBlock(drained, result, baseline, expectBackward: false)
    }

    func testDuplicateTimestampIsBackwardAndOverlapping() {
        let (drained, result, baseline) = overlapScenario(overlappedPTS: 0.04)
        assertOverlapDropsLateBlock(drained, result, baseline, expectBackward: true)
    }

    func testSequenceDisorderDropsLateSequenceWithoutOverwriting() {
        let refs = [
            MeetingReferencePCMFrame(sequenceNumber: 0, presentationTime: 0, sampleRate: 16_000,
                                     samples: [Float](repeating: 1, count: 160)),
            MeetingReferencePCMFrame(sequenceNumber: 2, presentationTime: 0.02, sampleRate: 16_000,
                                     samples: [Float](repeating: 3, count: 160)),
            MeetingReferencePCMFrame(sequenceNumber: 1, presentationTime: 0.01, sampleRate: 16_000,
                                     samples: [Float](repeating: 2, count: 160)),
            MeetingReferencePCMFrame(sequenceNumber: 3, presentationTime: 0.03, sampleRate: 16_000,
                                     samples: [Float](repeating: 4, count: 160)),
        ]
        let mics = (0..<4).map {
            MeetingMicrophonePCMFrame(sequenceNumber: $0, sampleTime: Int64($0 * 160),
                                      hostTime: Double($0) * 0.01, sampleRate: 16_000,
                                      samples: [Float](repeating: 5, count: 160))
        }
        let result = MeetingReferenceSynchronizer().synchronize(microphone: mics, reference: refs)

        XCTAssertEqual(result.diagnostics.duplicateOrLateFrameCount, 1)
        XCTAssertEqual(result.frames[1].renderValidMask, [Bool](repeating: false, count: 160))
        XCTAssertEqual(result.frames[2].renderSamples, [Float](repeating: 3, count: 160))
        XCTAssertTrue(result.frames[2].resynchronizationBoundary)
    }

    // MARK: Discontinuity, format/rate, route

    func testExplicitDiscontinuityWithContiguousTimingResetsWithoutGap() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        for index in 0..<10 {
            XCTAssertNil(adapter.appendRenderFrame(block(pts: Double(index) * 0.01,
                                                         discontinuity: index == 5)))
            XCTAssertNil(adapter.appendMicrophoneFrame(block(pts: Double(index) * 0.01,
                                                             arrival: Double(index) * 0.01)))
        }
        let (drained, result) = adapter.synchronize()

        XCTAssertEqual(drained.renderDiagnostics.discontinuityCount, 1)
        XCTAssertEqual(drained.renderDiagnostics.gapCount, 0)
        XCTAssertFalse(result.failedOpen)
        let hop = result.frames[5]
        XCTAssertEqual(hop.epochID, 1)
        XCTAssertTrue(hop.resynchronizationBoundary)
        XCTAssertTrue(hop.adaptationFrozen)
        XCTAssertFalse(hop.unknownReasons.contains(.referenceGap))
        XCTAssertTrue(hop.renderValidMask.allSatisfy { $0 })
    }

    func testUnsupportedRateAndFormatTransitionsAreRejectedAndCounted() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        XCTAssertNil(adapter.appendRenderFrame(block(pts: 0)))
        var shifted = block(pts: 0.01)
        shifted = MeetingStage05AdapterFrame(
            presentationSeconds: 0.01, durationSeconds: Double(blockFrames) / 44_100,
            frameCount: blockFrames, sampleRateHz: 44_100, arrivalSeconds: nil,
            samples: [Float](repeating: 0.5, count: blockFrames))
        XCTAssertEqual(adapter.appendRenderFrame(shifted), .unsupportedSampleRate)
        let drained = adapter.drain()
        XCTAssertEqual(drained.renderDiagnostics.rejectedCallbackCount, 1)
        XCTAssertEqual(drained.renderDiagnostics.formatChangeCount, 1)
        XCTAssertEqual(drained.reference.count, 1)
    }

    func testRejectedCallbackConsumesItsArrivalSequenceAndExposesTheHole() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        XCTAssertNil(adapter.appendRenderFrame(block(pts: 0)))
        let invalid = MeetingStage05AdapterFrame(
            presentationSeconds: .nan, durationSeconds: 0.01, frameCount: blockFrames,
            sampleRateHz: rate, arrivalSeconds: nil,
            samples: [Float](repeating: 0.5, count: blockFrames))
        XCTAssertEqual(adapter.appendRenderFrame(invalid), .nonFiniteTiming)
        XCTAssertNil(adapter.appendRenderFrame(block(pts: 0.02)))

        let drained = adapter.drain()
        XCTAssertEqual(drained.reference.map(\.sequenceNumber), [0, 2])
        XCTAssertEqual(drained.renderDiagnostics.acceptedCallbackCount, 2)
        XCTAssertEqual(drained.renderDiagnostics.rejectedCallbackCount, 1)
        XCTAssertEqual(drained.renderDiagnostics.gapCount, 1)
    }

    func testValidationRejectsBadTimingGeometryAndPayload() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let valid = block(pts: 0)
        func variant(_ mutate: (inout MeetingStage05AdapterFrame) -> Void) -> MeetingStage05AdapterFrame {
            var copy = valid; mutate(&copy); return copy
        }
        XCTAssertEqual(adapter.appendRenderFrame(variant { $0 = MeetingStage05AdapterFrame(
            presentationSeconds: .nan, durationSeconds: $0.durationSeconds, frameCount: $0.frameCount,
            sampleRateHz: $0.sampleRateHz, arrivalSeconds: nil, samples: $0.samples) }), .nonFiniteTiming)
        XCTAssertEqual(adapter.appendRenderFrame(variant { $0 = MeetingStage05AdapterFrame(
            presentationSeconds: -0.01, durationSeconds: $0.durationSeconds, frameCount: $0.frameCount,
            sampleRateHz: $0.sampleRateHz, arrivalSeconds: nil, samples: $0.samples) }), .negativeTiming)
        XCTAssertEqual(adapter.appendRenderFrame(variant { $0 = MeetingStage05AdapterFrame(
            presentationSeconds: 0, durationSeconds: 0.02, frameCount: $0.frameCount,
            sampleRateHz: $0.sampleRateHz, arrivalSeconds: nil, samples: $0.samples) }), .durationMismatch)
        XCTAssertEqual(adapter.appendRenderFrame(variant { $0 = MeetingStage05AdapterFrame(
            presentationSeconds: 0, durationSeconds: $0.durationSeconds, frameCount: $0.frameCount,
            sampleRateHz: $0.sampleRateHz, arrivalSeconds: nil,
            samples: [Float](repeating: 0.5, count: $0.frameCount - 1)) }), .invalidGeometry)
        XCTAssertEqual(adapter.appendRenderFrame(variant { $0 = MeetingStage05AdapterFrame(
            presentationSeconds: 0, durationSeconds: $0.durationSeconds, frameCount: $0.frameCount,
            sampleRateHz: $0.sampleRateHz, arrivalSeconds: nil,
            samples: [.nan] + [Float](repeating: 0.5, count: $0.frameCount - 1)) }), .nonFiniteSamples)
        XCTAssertEqual(adapter.drain().renderDiagnostics.rejectedCallbackCount, 5)
    }

    func testBlockAndFrameCeilingsBoundTheAdapter() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        for index in 0..<2_000 {
            XCTAssertNil(adapter.appendMicrophoneFrame(block(pts: Double(index) * 0.01,
                                                             arrival: Double(index) * 0.01)))
        }
        XCTAssertEqual(adapter.appendMicrophoneFrame(block(pts: 20, arrival: 20)), .blockLimit)

        let wide = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        for index in 0..<200 {
            XCTAssertNil(wide.appendMicrophoneFrame(block(pts: Double(index) * 0.1, frames: 4_800,
                                                          arrival: Double(index) * 0.1)))
        }
        XCTAssertEqual(wide.appendMicrophoneFrame(block(pts: 20, frames: 4_800, arrival: 20)), .frameLimit)
        XCTAssertEqual(wide.drain().microphone.count, 200)
    }

    // MARK: Drift ownership

    func testFailedOpenDriftThresholdAuthorizesNothing() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        feedPaired(adapter, count: 5)
        let (_, result) = adapter.synchronize(configuration: .init(
            referenceClockDriftPPM: 150, maximumClockDriftPPM: 100))
        XCTAssertTrue(result.failedOpen)
        XCTAssertEqual(result.failureReason, .clockDriftUnstable)
        XCTAssertEqual(result.diagnostics.referenceClockDriftPPM, 150)

        let seam = MeetingStage05MockAECSeam().process(result)
        XCTAssertFalse(seam.authorized)
        XCTAssertTrue(seam.events.isEmpty)
        XCTAssertEqual(seam.processedFrameCount, 0)
        XCTAssertEqual(seam.frames, result.frames)
    }

    func testEmptyOrStructurallyInvalidSynchronizationAuthorizesNothing() {
        let empty = MeetingReferenceSynchronizer().synchronize(microphone: [], reference: [])
        XCTAssertFalse(empty.failedOpen)
        let emptySeam = MeetingStage05MockAECSeam().process(empty)
        XCTAssertFalse(emptySeam.authorized)
        XCTAssertTrue(emptySeam.events.isEmpty)

        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        feedPaired(adapter, count: 1)
        let valid = adapter.synchronize().1
        let source = valid.frames[0]
        let malformedFrame = MeetingSynchronizedFrame(
            index: 1, sessionStartTime: source.sessionStartTime,
            sessionEndTime: source.sessionEndTime, epochID: source.epochID,
            renderSamples: source.renderSamples, captureSamples: source.captureSamples,
            renderValidMask: source.renderValidMask, captureValidMask: source.captureValidMask,
            unknownReasons: source.unknownReasons, adaptationFrozen: source.adaptationFrozen,
            resynchronizationBoundary: source.resynchronizationBoundary,
            lagSeconds: source.lagSeconds, timelines: source.timelines)
        let malformed = MeetingSynchronizationResult(
            frames: [malformedFrame], failedOpen: false, failureReason: nil,
            diagnostics: valid.diagnostics)
        let malformedSeam = MeetingStage05MockAECSeam().process(malformed)
        XCTAssertFalse(malformedSeam.authorized)
        XCTAssertTrue(malformedSeam.events.isEmpty)
        XCTAssertEqual(malformedSeam.frames, malformed.frames)
    }

    func testBoundedDriftIsReportedNotEstimatedFromCallbackPTS() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        feedPaired(adapter, count: 5)
        let (drained, result) = adapter.synchronize(configuration: .init(
            referenceClockDriftPPM: 90, maximumClockDriftPPM: 100))
        XCTAssertFalse(result.failedOpen)
        XCTAssertEqual(result.diagnostics.referenceClockDriftPPM, 90)
        XCTAssertTrue(result.frames.allSatisfy { $0.unknownReasons.contains(.clockDriftUnstable) })
        XCTAssertEqual(drained.renderDiagnostics.acceptedCallbackCount, 5)
    }

    // MARK: Deterministic replay

    func testAdapterSynchronizationIsDeterministic() {
        let first = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let second = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        feedPaired(first, count: 40, renderGap: (20, 0.002))
        feedPaired(second, count: 40, renderGap: (20, 0.002))
        XCTAssertEqual(first.drain(), second.drain())
        XCTAssertEqual(first.synchronize().1, second.synchronize().1)
    }

    // MARK: Synthetic CMSampleBuffer path

    func testSyntheticRenderBufferMapsPTSToPresentationTime() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let buffer = Stage05SyntheticBuffer.monoFloat32(pts: 1.25, frameCount: 480, value: 0.25)
        XCTAssertNotNil(buffer)
        XCTAssertNil(adapter.appendRender(buffer!, arrivalSeconds: 3.5))
        let drained = adapter.drain()
        XCTAssertEqual(drained.reference.count, 1)
        XCTAssertEqual(drained.reference[0].presentationTime, 1.25, accuracy: 1e-6)
        XCTAssertEqual(drained.reference[0].samples, [Float](repeating: 0.25, count: 480))
    }

    func testSyntheticMicrophoneBufferMapsPTSToSampleTimeAndArrivalToHostTime() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-b")
        let buffer = Stage05SyntheticBuffer.monoFloat32(pts: 0.5, frameCount: 480, value: 0.5)
        XCTAssertNotNil(buffer)
        XCTAssertNil(adapter.appendMicrophone(buffer!, arrivalSeconds: 9.75))
        let drained = adapter.drain()
        XCTAssertEqual(drained.microphone.count, 1)
        XCTAssertEqual(drained.microphone[0].sampleTime, 24_000)
        XCTAssertEqual(drained.microphone[0].hostTime, 9.75)
        XCTAssertEqual(drained.microphone[0].routeIdentifier, "route-b")
    }

    func testSyntheticBufferDiscontinuityAttachmentIsForwarded() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let buffer = Stage05SyntheticBuffer.monoFloat32(pts: 0, frameCount: 480, discontinuity: true)
        XCTAssertNotNil(buffer)
        XCTAssertNil(adapter.appendRender(buffer!, arrivalSeconds: 0))
        let drained = adapter.drain()
        XCTAssertEqual(drained.reference.first?.discontinuity, true)
        XCTAssertEqual(drained.renderDiagnostics.discontinuityCount, 1)
    }

    func testSyntheticStereoBufferIsRejectedAsFormatTransition() {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let stereo = Stage05SyntheticBuffer.monoFloat32(pts: 0, frameCount: 480, channels: 2)
        XCTAssertNotNil(stereo)
        XCTAssertEqual(adapter.appendRender(stereo!, arrivalSeconds: 0), .unsupportedFormat)
        let drained = adapter.drain()
        XCTAssertEqual(drained.renderDiagnostics.rejectedCallbackCount, 1)
        XCTAssertEqual(drained.renderDiagnostics.formatChangeCount, 1)
        XCTAssertTrue(drained.reference.isEmpty)
    }
}

final class MeetingStage05LiveAdapterRuntimeTests: XCTestCase {
    private final class MonotonicClock: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]
        private(set) var readCount = 0

        init(_ values: [Double]) { self.values = values }

        func now() -> Double {
            lock.lock(); defer { lock.unlock() }
            readCount += 1
            return values.isEmpty ? 0 : values.removeFirst()
        }
    }

    private func makeRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: "/private/tmp/fv-stage05-evidence.live-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(Darwin.chmod(root.path, 0o700), 0)
        return root
    }

    private func collector(at root: URL) throws -> MeetingStage05PCMCollector {
        try MeetingStage05PCMCollector(
            root: root, inputUID: "not-retained-input", outputUID: "not-retained-output",
            fixtureSHA256: String(repeating: "a", count: 64),
            executableSHA256: String(repeating: "b", count: 64),
            initialOutputVolume: 0.25, targetProcessID: 42)
    }

    func testRealStreamOutputRoutesBuffersAndReadsClockExactlyOncePerAudioCallback() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try collector(at: root)
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let clock = MonotonicClock([10, 11])
        let output = MeetingStage05StreamOutput(
            collector: collector, adapter: adapter, monotonicNow: clock.now)
        let render = try XCTUnwrap(Stage05SyntheticBuffer.monoFloat32(
            pts: 0, frameCount: 480, value: 0.02))
        let capture = try XCTUnwrap(Stage05SyntheticBuffer.monoFloat32(
            pts: 0, frameCount: 480, value: 0.01))

        output.handle(render, outputType: .audio)
        output.handle(capture, outputType: .microphone)
        output.handle(render, outputType: .screen)

        XCTAssertEqual(clock.readCount, 2)
        let drained = adapter.drain()
        XCTAssertEqual(drained.renderDiagnostics.acceptedCallbackCount, 1)
        XCTAssertEqual(drained.microphoneDiagnostics.acceptedCallbackCount, 1)
        XCTAssertEqual(drained.microphone.first?.hostTime, 11)

        collector.retainTimingFailureRecord(.renderTiming)
        let record = try JSONDecoder().decode(
            MeetingStage05TimingFailureRecord.self,
            from: Data(contentsOf: root.appendingPathComponent("timing.json")))
        XCTAssertEqual(record.render.blocks.first?.arrivalSeconds, 10)
        XCTAssertEqual(record.capture.blocks.first?.arrivalSeconds, 11)
    }

    func testRealStreamOutputCountsAdapterRejectionAndCollectorFailsClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try collector(at: root)
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        let output = MeetingStage05StreamOutput(
            collector: collector, adapter: adapter, monotonicNow: { 10 })
        let stereo = try XCTUnwrap(Stage05SyntheticBuffer.monoFloat32(
            pts: 0, frameCount: 480, channels: 2))

        output.handle(stereo, outputType: .audio)

        let drained = adapter.drain()
        XCTAssertEqual(drained.renderDiagnostics.rejectedCallbackCount, 1)
        XCTAssertEqual(drained.renderDiagnostics.formatChangeCount, 1)
        XCTAssertThrowsError(
            try collector.finish(consentConfirmed: true, finalOutputVolume: 0.25)) {
            XCTAssertEqual($0 as? MeetingStage05FinalizeFailure, .appendInvalidFrame)
        }
        collector.abort()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testContiguousSummaryIsValidEligibleAndSortedWithoutSensitiveFields() throws {
        let summary = makeSummary(renderGapSeconds: 0)
        XCTAssertTrue(summary.validationReasons().isEmpty)
        XCTAssertTrue(summary.structurallyValid)
        XCTAssertTrue(summary.eligibleForAECTrial)
        XCTAssertEqual(summary.mockProcessedFrameCount, summary.synchronizerOutputFrameCount)
        XCTAssertEqual(summary.mockFrozenFrameCount, 0)

        let encoded = MeetingStage05EvidenceAutorun.encodedOutcome(
            exitStatus: 0, status: "success", adapter: summary)
        XCTAssertTrue(encoded.hasPrefix("{\"adapter\":"), encoded)
        let data = Data(encoded.utf8)
        let decoded = try JSONDecoder().decode(MeetingStage05AutorunOutcome.self, from: data)
        XCTAssertEqual(decoded.adapter, summary)
        let object = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["adapter"]
                as? [String: Any])
        XCTAssertTrue(object.values.allSatisfy { $0 is NSNumber })
        let lower = encoded.lowercased()
        for forbidden in ["samples", "peak", "uid", "pid", "title", "path", "transcript",
                          "sha256", "fixture", "executable", "timestamp"] {
            XCTAssertFalse(lower.contains(forbidden), "forbidden outcome field: \(forbidden)")
        }
    }

    func testGapSummaryRemainsStructurallyValidButCannotAuthorizeAECTrial() {
        let summary = makeSummary(renderGapSeconds: 0.002)
        XCTAssertTrue(summary.validationReasons().isEmpty)
        XCTAssertTrue(summary.structurallyValid)
        XCTAssertFalse(summary.eligibleForAECTrial)
        XCTAssertEqual(summary.renderGapCount, 1)
        XCTAssertGreaterThan(summary.mockFrozenFrameCount, 0)
        XCTAssertGreaterThan(summary.mockBoundaryCount, 0)
        XCTAssertTrue(summary.renderBeforeCaptureValid)
    }

    func testSummaryRejectsTamperedEligibilityAndNonfiniteDrift() throws {
        let valid = makeSummary(renderGapSeconds: 0)
        let data = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["eligibleForAECTrial"] = false
        object["referenceClockDriftPPM"] = 1.0
        object["referenceClockDriftPresent"] = false
        let tampered = try JSONDecoder().decode(
            MeetingStage05LiveAdapterSummary.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(tampered.validationReasons().contains("eligibility"))
        XCTAssertTrue(tampered.validationReasons().contains("drift"))

        XCTAssertEqual(
            MeetingStage05EvidenceAutorun.encodedOutcome(
                exitStatus: 0, status: "success", adapter: tampered),
            "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"outcome\"}")
    }

    private func makeSummary(renderGapSeconds: Double) -> MeetingStage05LiveAdapterSummary {
        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "route-a")
        for index in 0..<10 {
            let base = Double(index) * 0.01
            let renderPTS = index >= 5 ? base + renderGapSeconds : base
            XCTAssertNil(adapter.appendRenderFrame(MeetingStage05AdapterFrame(
                presentationSeconds: renderPTS, durationSeconds: 0.01,
                frameCount: 480, sampleRateHz: 48_000,
                arrivalSeconds: 1 + base, samples: [Float](repeating: 0.02, count: 480))))
            XCTAssertNil(adapter.appendMicrophoneFrame(MeetingStage05AdapterFrame(
                presentationSeconds: base, durationSeconds: 0.01,
                frameCount: 480, sampleRateHz: 48_000,
                arrivalSeconds: 1 + base, samples: [Float](repeating: 0.01, count: 480))))
        }
        let (drain, synchronization) = adapter.synchronize(configuration: .init(
            referenceScope: .selectedWindow,
            referenceCompleteness: .measuredComplete))
        let seam = MeetingStage05MockAECSeam().process(synchronization)
        return MeetingStage05LiveAdapterSummary.make(
            drain: drain, synchronization: synchronization, seam: seam)
    }
}

final class MeetingStage05TimingFailureRecordTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: "/private/tmp/fv-stage05-evidence.unit-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(Darwin.chmod(root.path, 0o700), 0)
        return root
    }

    private func collector(at root: URL) throws -> MeetingStage05PCMCollector {
        try MeetingStage05PCMCollector(
            root: root, inputUID: "not-retained-input", outputUID: "not-retained-output",
            fixtureSHA256: String(repeating: "a", count: 64),
            executableSHA256: String(repeating: "b", count: 64),
            initialOutputVolume: 0.25, targetProcessID: 42)
    }

    private func appendShortTimingFailureFixture(_ collector: MeetingStage05PCMCollector) {
        for index in 0..<4 {
            let base = Double(index) * 0.01
            let renderPTS = index >= 2 ? base + 0.002 : base
            let render = Stage05SyntheticBuffer.monoFloat32(
                pts: renderPTS, frameCount: 480, value: 0.02)!
            let capture = Stage05SyntheticBuffer.monoFloat32(
                pts: base, frameCount: 480, value: 0.01)!
            collector.append(render, output: .render)
            collector.append(capture, output: .capture)
        }
    }

    func testCompletedTimingFailureRetainsOnlyMode0600NumericRecord() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try collector(at: root)
        appendShortTimingFailureFixture(collector)

        XCTAssertThrowsError(try collector.finish(consentConfirmed: true, finalOutputVolume: 0.25)) {
            XCTAssertEqual($0 as? MeetingStage05FinalizeFailure, .renderTiming)
        }
        collector.retainTimingFailureRecord(.renderTiming)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["timing.json"])
        let timingURL = root.appendingPathComponent("timing.json")
        let mode = (try FileManager.default.attributesOfItem(atPath: timingURL.path)[.posixPermissions]
            as? NSNumber)?.intValue
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)
        let data = try Data(contentsOf: timingURL)
        let record = try JSONDecoder().decode(MeetingStage05TimingFailureRecord.self, from: data)
        XCTAssertTrue(record.validationReasons().isEmpty)
        XCTAssertEqual(record.failure, MeetingStage05FinalizeFailure.renderTiming.rawValue)
        XCTAssertEqual(record.track, "render")
        XCTAssertEqual(record.sampleRateHz, 48_000)
        XCTAssertEqual(record.render.blocks.count, 4)
        XCTAssertEqual(record.capture.blocks.count, 4)
        XCTAssertGreaterThanOrEqual(record.render.gapCount, 1)

        let encoded = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["\"samples\"", "\"peak\"", "uid", "pid", "title", "path",
                          "transcript", "sha256", "fixture", "executable"] {
            XCTAssertFalse(encoded.contains(forbidden), "forbidden timing-record key: \(forbidden)")
        }
        for absent in ["render.wav", "capture.wav", "manifest.json", "provenance.json"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(absent).path))
        }
    }

    func testTimingRecordRejectsTamperedDerivedCounts() {
        let blocks = [
            MeetingSignalDomainGateManifest.TimingBlock(
                presentationSeconds: 0, durationSeconds: 0.01,
                frameCount: 480, arrivalSeconds: 1),
            MeetingSignalDomainGateManifest.TimingBlock(
                presentationSeconds: 0.012, durationSeconds: 0.01,
                frameCount: 480, arrivalSeconds: 1.01),
        ]
        let valid = MeetingStage05TimingFailureRecord.make(
            failure: .renderTiming, renderTiming: blocks, captureTiming: blocks,
            sampleRateHz: 48_000)
        XCTAssertTrue(valid.validationReasons().isEmpty)
        let tamperedRender = MeetingStage05TimingFailureRecord.Track(
            blocks: valid.render.blocks, gapCount: valid.render.gapCount + 1,
            overlapCount: valid.render.overlapCount, backwardCount: valid.render.backwardCount,
            formatChangeCount: valid.render.formatChangeCount)
        let tampered = MeetingStage05TimingFailureRecord(
            schema: valid.schema, failure: valid.failure, track: valid.track,
            sampleRateHz: valid.sampleRateHz, render: tamperedRender, capture: valid.capture)
        XCTAssertTrue(tampered.validationReasons().contains("derivedCounts"))
    }

    func testNonTimingRetainRequestDeletesEveryArtifact() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try collector(at: root)
        appendShortTimingFailureFixture(collector)
        collector.retainTimingFailureRecord(.renderSilent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testEmergencyCleanupDeletesTheFixedTimingAndAudioNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["render.wav", "capture.wav", "manifest.json", "provenance.json", "timing.json"] {
            try Data([0]).write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
        }
        MeetingStage05PCMCollector.emergencyCleanup(at: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}

private extension MeetingStage05AdapterTrackDiagnostics {
    init(accepted: Int) {
        self.init(acceptedCallbackCount: accepted, rejectedCallbackCount: 0, gapCount: 0,
                  overlapCount: 0, backwardCount: 0, discontinuityCount: 0, formatChangeCount: 0)
    }
}

#endif
