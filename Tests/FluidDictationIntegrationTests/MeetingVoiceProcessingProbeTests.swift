#if DEBUG
@testable import FluidVoice_Debug
import AudioToolbox
import AVFoundation
import XCTest

final class MeetingVoiceProcessingProbeTests: XCTestCase {
    func testVPIOAcousticGateRequiresBothFlagsAndBoundedDuration() {
        XCTAssertFalse(MeetingVPIOAcousticGate.isEnabled(environment: [:]))
        XCTAssertFalse(MeetingVPIOAcousticGate.isEnabled(environment: ["FLUIDVOICE_MIC_PHASE1": "0.05"]))
        XCTAssertFalse(MeetingVPIOAcousticGate.isEnabled(environment: ["FLUIDVOICE_VPIO_ACOUSTIC": "1", "FLUIDVOICE_MIC_PHASE1": "0.250001"]))
        XCTAssertFalse(MeetingVPIOAcousticGate.isEnabled(environment: ["FLUIDVOICE_VPIO_ACOUSTIC": "1", "FLUIDVOICE_MIC_PHASE1": "nan"]))
        XCTAssertTrue(MeetingVPIOAcousticGate.isEnabled(environment: ["FLUIDVOICE_VPIO_ACOUSTIC": "1", "FLUIDVOICE_MIC_PHASE1": "0.25"]))
    }

    func testTrialBConvertsFirstActivityToStimulusSampleZero() {
        XCTAssertEqual(
            MeetingVPIOAcousticTrialB.stimulusSampleZeroHostSeconds(
                renderActivityStartHostSeconds: 10.2,
                leadingSilenceFrameCount: 9_600,
                sampleRate: 48_000
            )!,
            10.0,
            accuracy: 1e-12
        )
        XCTAssertNil(MeetingVPIOAcousticTrialB.stimulusSampleZeroHostSeconds(
            renderActivityStartHostSeconds: .infinity,
            leadingSilenceFrameCount: 9_600,
            sampleRate: 48_000
        ))
    }

    func testAcousticCollectorReportsGapOverlapAndSynthesizedTiming() throws {
        let collector = MeetingVPIOAcousticCaptureCollector()
        let empty = collector.window(startHostSeconds: 0, frameCount: 4, sampleRate: 48_000)
        XCTAssertLessThan(empty.window.coverage, 1)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        func sampleBuffer() throws -> CMSampleBuffer {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
            pcm.frameLength = 4
            pcm.floatChannelData![0].update(repeating: 0.1, count: 4)
            return try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(
                from: pcm, presentationTime: CMTime.zero
            ))
        }
        let first = try sampleBuffer()
        collector.ingest(first, synthesized: true, resynced: false)
        collector.ingest(try sampleBuffer(), synthesized: false, resynced: true)
        let window = collector.window(startHostSeconds: 0, frameCount: 4, sampleRate: 48_000)
        XCTAssertGreaterThan(window.window.overlapFrameCount, 0)
        XCTAssertGreaterThan(window.window.synthesizedFrameCount, 0)
        XCTAssertGreaterThan(window.window.resyncedSegmentCount, 0)
    }

    func testVPIOStimulusIsDeterministicAndWithinSafetyBounds() throws {
        let first = try XCTUnwrap(MeetingVPIOAcousticStimulus.make(sampleRate: 16_000))
        let second = try XCTUnwrap(MeetingVPIOAcousticStimulus.make(sampleRate: 16_000))
        XCTAssertEqual(first.samples, second.samples)
        XCTAssertTrue(first.descriptor.withinSafetyBounds)
        XCTAssertLessThanOrEqual(first.descriptor.measuredPeak, first.descriptor.safetyPeakLimit)
        XCTAssertGreaterThan(first.descriptor.measuredRMS, first.descriptor.safetyMinimumRMS)
    }

    func testVPIOMetricsReportsPositiveSignedDelayWhenCaptureLags() throws {
        let sampleRate = 16_000.0
        // Use the same bounded, alignment-rich stimulus family as the hardware trial. A pair of
        // steady tones is intentionally avoided: its repeated phase makes split-half delay
        // agreement ambiguous and should be reported as uncertainty, not treated as a pass.
        let stimulus = try XCTUnwrap(MeetingVPIOAcousticStimulus.make(sampleRate: sampleRate))
        let reference = stimulus.samples
        let delay = 240
        var captured = Array(repeating: Float.zero, count: reference.count)
        captured.replaceSubrange(delay..<reference.count, with: reference[0..<(reference.count - delay)])
        let measurement = MeetingVPIOAcousticMetrics.measure(
            reference: reference, captured: captured, sampleRate: sampleRate, silencePrefixFrames: 0
        )
        XCTAssertTrue(measurement.delay.resolved, "reasons=\(measurement.delay.reasons)")
        XCTAssertEqual(measurement.delay.signedSeconds!, Double(delay) / sampleRate, accuracy: 2 / sampleRate)
        XCTAssertGreaterThanOrEqual(measurement.bands.count, 4)
    }

    func testVPIOMetricsRejectsNegativeSignedDelay() throws {
        let sampleRate = 16_000.0
        let stimulus = try XCTUnwrap(MeetingVPIOAcousticStimulus.make(sampleRate: sampleRate))
        let advance = 240
        var captured = Array(repeating: Float.zero, count: stimulus.samples.count)
        captured.replaceSubrange(
            0..<(stimulus.samples.count - advance),
            with: stimulus.samples[advance..<stimulus.samples.count]
        )

        let measurement = MeetingVPIOAcousticMetrics.measure(
            reference: stimulus.samples,
            captured: captured,
            sampleRate: sampleRate,
            silencePrefixFrames: 0
        )
        XCTAssertLessThan(measurement.delay.signedSeconds ?? 0, 0)
        XCTAssertFalse(measurement.delay.resolved)
        XCTAssertTrue(measurement.delay.reasons.contains(.negativeDelay))
    }

    func testVPIOMetricsMarksSilenceLowExcitationAndMismatchedControlUnknown() {
        let silence = Array(repeating: Float.zero, count: 5_000)
        let silentMeasurement = MeetingVPIOAcousticMetrics.measure(
            reference: silence, captured: silence, sampleRate: 16_000, silencePrefixFrames: 1_024
        )
        XCTAssertFalse(silentMeasurement.valid)
        XCTAssertTrue(silentMeasurement.reasons.contains(.referenceBelowExcitationFloor))

        let reference = (0..<12_000).map { Float(sin(Double($0) * 0.173)) }
        let control = (0..<12_000).map { Float(cos(Double($0) * 0.093 + 0.8)) }
        let controlMeasurement = MeetingVPIOAcousticMetrics.measure(
            reference: reference, captured: control, sampleRate: 16_000, silencePrefixFrames: 0
        )
        XCTAssertFalse(controlMeasurement.valid)
        XCTAssertTrue(
            controlMeasurement.reasons.contains(.delayConfidenceBelowThreshold)
                || controlMeasurement.reasons.contains(.delayUnresolved)
                || controlMeasurement.reasons.contains(.tooFewCoherentBands)
        )
    }

    func testVPIOTrialBReportJSONRoundTripHasNoRawSamples() throws {
        let stimulus = try XCTUnwrap(MeetingVPIOAcousticStimulus.make(sampleRate: 16_000))
        let report = MeetingVPIOAcousticTrialBReport(
            schemaVersion: MeetingVPIOAcousticTrialBReport.currentSchemaVersion,
            stimulus: stimulus.descriptor, renderVolume: 0.5, preRollSeconds: 0.3,
            postRollSeconds: 0.6, settleSeconds: 0.35, runs: [],
            caveats: MeetingVPIOAcousticTrialBReport.interpretationCaveats
        )
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(MeetingVPIOAcousticTrialBReport.self, from: data), report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("samples"))
        XCTAssertFalse(json.contains("transcript"))
    }

    func testFailedUInt32ReadbackNeverPublishesValue() {
        let readback = MeetingAudioUnitUInt32Readback(
            propertyID: kAUVoiceIOProperty_BypassVoiceProcessing,
            scope: kAudioUnitScope_Global,
            element: 0,
            status: kAudioUnitErr_InvalidProperty,
            value: 42
        )

        XCTAssertFalse(readback.succeeded)
        XCTAssertNil(readback.value)
    }

    func testFailedDuckingReadbackNeverPublishesFields() {
        let readback = MeetingAudioUnitDuckingReadback(
            propertyID: kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
            scope: kAudioUnitScope_Global,
            element: 0,
            status: kAudioUnitErr_InvalidProperty,
            advancedDuckingEnabled: true,
            duckingLevelRawValue: 30
        )

        XCTAssertNil(readback.advancedDuckingEnabled)
        XCTAssertNil(readback.duckingLevelRawValue)
    }

    func testProbeSnapshotJSONRoundTripPreservesRawEvidence() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let successfulRead = MeetingAudioUnitUInt32Readback(
            propertyID: kAUVoiceIOProperty_VoiceProcessingEnableAGC,
            scope: kAudioUnitScope_Global,
            element: 0,
            status: noErr,
            value: 1
        )
        let snapshot = MeetingVoiceProcessingProbeSnapshot(
            schemaVersion: MeetingVoiceProcessingProbeSnapshot.currentSchemaVersion,
            engineRunning: true,
            nodeVoiceProcessingEnabled: true,
            nodeVoiceProcessingBypassed: false,
            nodeVoiceProcessingAGCEnabled: true,
            nodeVoiceProcessingInputMuted: false,
            nodeAdvancedDuckingEnabled: false,
            nodeDuckingLevelRawValue: 10,
            inputPresentationLatencySeconds: 0.01,
            outputPresentationLatencySeconds: 0.02,
            inputNodeInputFormat: MeetingAudioFormatProbeReadback(format),
            inputNodeOutputFormat: MeetingAudioFormatProbeReadback(format),
            outputNodeInputFormat: MeetingAudioFormatProbeReadback(format),
            outputNodeOutputFormat: MeetingAudioFormatProbeReadback(format),
            inputNodeLastRenderTime: MeetingAudioTimeProbeReadback(nil),
            outputNodeLastRenderTime: MeetingAudioTimeProbeReadback(nil),
            inputNodeOutputConnectionCount: 0,
            inputCurrentDevice: successfulRead,
            outputCurrentDevice: successfulRead,
            bypassVoiceProcessing: successfulRead,
            voiceProcessingAGCEnabled: successfulRead,
            voiceProcessingOutputMuted: successfulRead,
            otherAudioDucking: MeetingAudioUnitDuckingReadback(
                propertyID: kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                scope: kAudioUnitScope_Global,
                element: 0,
                status: noErr,
                advancedDuckingEnabled: false,
                duckingLevelRawValue: 10
            )
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MeetingVoiceProcessingProbeSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.voiceProcessingAGCEnabled.value, 1)
        XCTAssertEqual(decoded.otherAudioDucking.duckingLevelRawValue, 10)
    }
}
#endif
