#if DEBUG

@testable import FluidVoice_Debug
import AVFoundation
import CoreMedia
import Foundation
import XCTest

final class MeetingSCKPairedDiagnosticsTests: XCTestCase {
    private let enabledEnvironment = [MeetingSCKPairedDiagnosticGate.environmentKey: "1"]

    private func sample(
        _ output: MeetingSCKPairedOutput,
        pts: Double,
        duration: Double = 0.02,
        arrival: Double? = nil,
        rate: Double = 48_000,
        channels: Int = 2
    ) -> MeetingSCKPairedDiagnosticSample {
        .init(output: output, presentationSeconds: pts, durationSeconds: duration,
              frameCount: Int((duration * rate).rounded()), sampleRateHz: rate,
              channelCount: channels, arrivalSeconds: arrival)
    }

    func testGateIsExplicitAndDisabledReportsNoSamples() throws {
        let collector = MeetingSCKPairedDiagnosticCollector(environment: [:])
        XCTAssertFalse(collector.enabled)
        collector.record(sample(.applicationAudio, pts: 1))
        let report = collector.report()
        XCTAssertFalse(report.enabled)
        XCTAssertEqual(report.acceptedSampleCount, 0)
        XCTAssertFalse(report.rawPCMRetained)
        XCTAssertFalse(report.transcriptRetained)
        XCTAssertTrue(report.failOpen)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
    }

    func testTracksFormatContinuityGapJitterAndOffsetWithoutClockClaim() throws {
        let collector = MeetingSCKPairedDiagnosticCollector(environment: enabledEnvironment)
        collector.record(sample(.applicationAudio, pts: 100, arrival: 0))
        collector.record(sample(.applicationAudio, pts: 100.02, arrival: 0.025))
        collector.record(sample(.applicationAudio, pts: 100.04, arrival: 0.04, channels: 1))
        collector.record(sample(.microphone, pts: 100.08, arrival: 0.01))
        collector.record(sample(.microphone, pts: 100.10, arrival: 0.03))
        collector.record(sample(.microphone, pts: 100.14, arrival: 0.08))

        let report = collector.report()
        XCTAssertEqual(report.acceptedSampleCount, 6)
        XCTAssertEqual(report.schemaVersion, 3)
        XCTAssertEqual(report.application.sampleCount, 3)
        XCTAssertEqual(report.application.formatChangeCount, 1)
        XCTAssertEqual(report.application.jitterObservationCount, 2)
        XCTAssertEqual(report.application.meanAbsoluteJitterSeconds!, 0.005, accuracy: 0.000_001)
        XCTAssertEqual(report.microphone.gapCount, 1)
        XCTAssertEqual(report.microphone.gapDurationSeconds, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(report.crossTrack.firstPresentationOffsetSeconds!, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(report.crossTrack.relativeTimestampSpanDifferencePPM!,
                       ((report.microphone.timestampSpanSeconds! / report.application.timestampSpanSeconds!) - 1) * 1_000_000,
                       accuracy: 0.001)
        XCTAssertFalse(report.crossTrack.sharedClockEstablished)
        XCTAssertNil(report.crossTrack.acousticDelaySeconds)
        XCTAssertFalse(report.crossTrack.aecEvaluated)
        XCTAssertTrue(report.crossTrack.timestampRelationship.contains("delivery-window"))
        XCTAssertTrue(report.crossTrack.timestampRelationship.contains("not identifiable"))
    }

    func testTimestampContinuityToleranceIgnoresNanosecondNoiseButDetectsOneSample() {
        let rate = 48_000.0
        let epsilon = 1e-9
        let contiguous = MeetingSCKPairedDiagnosticCollector(environment: enabledEnvironment)
        contiguous.record(sample(.microphone, pts: 0, rate: rate, channels: 1))
        contiguous.record(sample(.microphone, pts: 0.02 + epsilon, rate: rate, channels: 1))
        contiguous.record(sample(.microphone, pts: 0.04 - epsilon, rate: rate, channels: 1))
        let contiguousReport = contiguous.report().microphone
        XCTAssertEqual(contiguousReport.gapCount, 0)
        XCTAssertEqual(contiguousReport.overlapCount, 0)
        XCTAssertEqual(contiguousReport.backwardsTimestampCount, 0)

        let oneSampleGap = MeetingSCKPairedDiagnosticCollector(environment: enabledEnvironment)
        oneSampleGap.record(sample(.microphone, pts: 0, rate: rate, channels: 1))
        oneSampleGap.record(sample(.microphone, pts: 0.02 + 1 / rate, rate: rate, channels: 1))
        XCTAssertEqual(oneSampleGap.report().microphone.gapCount, 1)
        XCTAssertEqual(oneSampleGap.report().microphone.gapDurationSeconds, 1 / rate, accuracy: 1e-12)

        let oneSampleOverlap = MeetingSCKPairedDiagnosticCollector(environment: enabledEnvironment)
        oneSampleOverlap.record(sample(.microphone, pts: 0, rate: rate, channels: 1))
        oneSampleOverlap.record(sample(.microphone, pts: 0.02 - 1 / rate, rate: rate, channels: 1))
        XCTAssertEqual(oneSampleOverlap.report().microphone.overlapCount, 1)
    }

    func testMalformedMetadataAndSampleBoundAreNumericAndBounded() {
        let collector = MeetingSCKPairedDiagnosticCollector(
            configuration: .init(maximumSamples: 2), environment: enabledEnvironment
        )
        collector.record(sample(.applicationAudio, pts: 1))
        collector.record(.init(output: .applicationAudio, presentationSeconds: .nan, durationSeconds: 0.02,
                               frameCount: 960, sampleRateHz: 48_000, channelCount: 2))
        collector.record(sample(.microphone, pts: 1))
        collector.record(sample(.microphone, pts: 2))

        let report = collector.report()
        XCTAssertEqual(report.acceptedSampleCount, 2)
        XCTAssertEqual(report.droppedAfterBoundCount, 2)
        XCTAssertEqual(report.application.malformedMetadataCount, 1)
        XCTAssertEqual(report.application.invalidTimestampCount, 1)
        XCTAssertEqual(report.microphone.sampleCount, 0)
        XCTAssertEqual(report.boundedMaximumSamples, 2)
    }

    func testReportIsNumericAndDoesNotContainRawAudioOrTextFields() throws {
        let collector = MeetingSCKPairedDiagnosticCollector(environment: enabledEnvironment)
        collector.record(sample(.microphone, pts: 3))
        let data = try collector.report().jsonData()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["samples"])
        XCTAssertNil(json["pcm"])
        XCTAssertNil(json["transcript"])
        XCTAssertEqual(json["rawPCMRetained"] as? Bool, false)
        XCTAssertEqual(json["transcriptRetained"] as? Bool, false)
    }

    func testDeterministicHarnessConsumesMetadataOnly() {
        let report = MeetingSCKPairedDiagnosticHarness.run(
            [sample(.applicationAudio, pts: 2), sample(.microphone, pts: 2.1, channels: 1)],
            environment: enabledEnvironment
        )
        XCTAssertEqual(report.acceptedSampleCount, 2)
        XCTAssertEqual(report.application.sampleCount, 1)
        XCTAssertEqual(report.microphone.sampleCount, 1)
        XCTAssertTrue(report.failOpen)
    }

    func testCallbackSeamRequiresStableSelectedApplicationProvenance() {
        let collector = MeetingSCKPairedDiagnosticCollector(environment: enabledEnvironment)
        let sample = sample(.applicationAudio, pts: 4)
        let unconfirmed = MeetingSCKPairedDiagnosticProvenance(
            scope: .selectedApplicationWindow, applicationSelectionConfirmed: false
        )
        XCTAssertFalse(collector.record(sample, provenance: unconfirmed))
        XCTAssertEqual(collector.report().acceptedSampleCount, 0)

        let confirmed = MeetingSCKPairedDiagnosticProvenance(
            scope: .selectedApplicationWindow, applicationSelectionConfirmed: true
        )
        XCTAssertTrue(collector.record(sample, provenance: confirmed))
        XCTAssertFalse(collector.record(sample, provenance: .init(
            scope: .selectedApplicationDisplay, applicationSelectionConfirmed: true
        )))
        let report = collector.report()
        XCTAssertEqual(report.acceptedSampleCount, 1)
        XCTAssertEqual(report.provenance, confirmed)
        XCTAssertEqual(report.rejectedProvenanceCount, 2)
        XCTAssertFalse(report.rawPCMRetained)
        XCTAssertFalse(report.transcriptRetained)
    }

    func testDisabledCallbackSeamDoesNotAdmitMetadata() {
        let collector = MeetingSCKPairedDiagnosticCollector(environment: [:])
        let provenance = MeetingSCKPairedDiagnosticProvenance(
            scope: .selectedApplicationDisplay, applicationSelectionConfirmed: true
        )
        XCTAssertFalse(collector.record(
            sample(.microphone, pts: 5), provenance: provenance
        ))
        XCTAssertEqual(collector.report().acceptedSampleCount, 0)
        XCTAssertNil(collector.report().provenance)
        XCTAssertEqual(collector.report().rejectedProvenanceCount, 0)
    }

    func testHardwareGateRequiresBothFlagsAndTargetBundleID() {
        XCTAssertFalse(MeetingSCKPairedDiagnosticGate.hardwareEnabled(environment: [:]))
        XCTAssertFalse(MeetingSCKPairedDiagnosticGate.hardwareEnabled(environment: [
            MeetingSCKPairedDiagnosticGate.environmentKey: "1",
            MeetingSCKPairedDiagnosticGate.hardwareEnvironmentKey: "1"
        ]))
        XCTAssertFalse(MeetingSCKPairedDiagnosticGate.hardwareEnabled(environment: [
            MeetingSCKPairedDiagnosticGate.environmentKey: "1",
            MeetingSCKPairedDiagnosticGate.targetBundleIDEnvironmentKey: "com.example.Meeting"
        ]))
        XCTAssertTrue(MeetingSCKPairedDiagnosticGate.hardwareEnabled(environment: [
            MeetingSCKPairedDiagnosticGate.environmentKey: "1",
            MeetingSCKPairedDiagnosticGate.hardwareEnvironmentKey: "1",
            MeetingSCKPairedDiagnosticGate.targetBundleIDEnvironmentKey: "com.example.Meeting"
        ]))
    }

    func testAutorunGateRequiresAdditionalExactFlag() {
        let hardware = [
            MeetingSCKPairedDiagnosticGate.environmentKey: "1",
            MeetingSCKPairedDiagnosticGate.hardwareEnvironmentKey: "1",
            MeetingSCKPairedDiagnosticGate.targetBundleIDEnvironmentKey: "com.example.Meeting"
        ]
        XCTAssertFalse(MeetingSCKPairedDiagnosticGate.autorunEnabled(environment: hardware))
        XCTAssertFalse(MeetingSCKPairedDiagnosticGate.autorunEnabled(environment: hardware.merging([
            MeetingSCKPairedDiagnosticGate.autorunEnvironmentKey: "true"
        ]) { _, new in new }))
        XCTAssertTrue(MeetingSCKPairedDiagnosticGate.autorunEnabled(environment: hardware.merging([
            MeetingSCKPairedDiagnosticGate.autorunEnvironmentKey: "1"
        ]) { _, new in new }))
        XCTAssertFalse(MeetingSCKPairedAutorun.startIfRequested(environment: [:]))
    }

    func testAutorunTimeoutBudgetHasHardWatchdogHeadroom() {
        XCTAssertGreaterThan(MeetingSCKPairedAutorun.hardWatchdogSeconds,
                             MeetingSCKPairedAutorun.maximumRunSeconds)
        XCTAssertLessThanOrEqual(MeetingSCKPairedAutorun.hardWatchdogSeconds, 15)
    }

    func testSampleBufferCallbackCopiesNumericMetadataOnly() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        pcm.frameLength = 960
        let buffer = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(
            from: pcm, presentationTime: CMTime(value: 12, timescale: 1)
        ))
        let provenance = MeetingSCKPairedDiagnosticProvenance(
            scope: .selectedApplicationWindow, applicationSelectionConfirmed: true
        )
        let collector = MeetingSCKPairedDiagnosticCollector(environment: enabledEnvironment)

        XCTAssertTrue(collector.record(sampleBuffer: buffer, output: .microphone, provenance: provenance))
        let report = collector.report()
        XCTAssertEqual(report.microphone.sampleCount, 1)
        XCTAssertEqual(report.microphone.validTimestampCount, 1)
        XCTAssertEqual(report.microphone.firstSampleRateHz ?? .nan, 48_000, accuracy: 0.001)
        XCTAssertEqual(report.microphone.firstChannelCount, 1)
        XCTAssertEqual(report.provenance, provenance)
        XCTAssertFalse(report.rawPCMRetained)
        XCTAssertFalse(report.transcriptRetained)
    }

    func testTrialAGateIsSeparateAndChromeOnly() {
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.autorunEnabled(environment: [
            MeetingExternalReferenceTrialAGate.environmentKey: "1",
            MeetingExternalReferenceTrialAGate.autorunEnvironmentKey: "1",
            MeetingExternalReferenceTrialAGate.targetBundleIDEnvironmentKey: "com.example.App"
        ]))
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.autorunEnabled(environment: [
            MeetingExternalReferenceTrialAGate.environmentKey: "1",
            MeetingExternalReferenceTrialAGate.autorunEnvironmentKey: "1",
            MeetingSCKPairedDiagnosticGate.targetBundleIDEnvironmentKey: "com.google.Chrome"
        ]))
        XCTAssertTrue(MeetingExternalReferenceTrialAGate.autorunEnabled(environment: [
            MeetingExternalReferenceTrialAGate.environmentKey: "1",
            MeetingExternalReferenceTrialAGate.autorunEnvironmentKey: "1",
            MeetingExternalReferenceTrialAGate.targetBundleIDEnvironmentKey: "com.google.Chrome"
        ]))
    }

    func testTrialARequiresTheControlledStimulusToBePlaying() {
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(title: nil))
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(
            title: "FluidVoice C2 Diagnostic Stimulus — Ready"))
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(
            title: "FluidVoice C2 Diagnostic Stimulus — Complete"))
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(
            title: "FluidVoice C2 Diagnostic Stimulus — NOT PLAYING - Google Chrome"))
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(
            title: "FluidVoice C2 Diagnostic Stimulus — PLAYINGISH - Google Chrome"))
        XCTAssertTrue(MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(
            title: "FluidVoice C2 Diagnostic Stimulus — PLAYING - Google Chrome"))
        XCTAssertFalse(MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(
            title: "Unrelated PLAYING - Google Chrome"))
    }

    func testTrialASelectsUniqueDisplayWithMaximumWindowIntersection() {
        let left = MeetingExternalReferenceTrialADisplayCandidate(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let right = MeetingExternalReferenceTrialADisplayCandidate(
            displayID: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800))
        let window = CGRect(x: 800, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            MeetingExternalReferenceTrialADisplaySelector.selectDisplayID(
                windowFrame: window, displays: [left, right]), 2)
    }

    func testTrialADisplaySelectionFailsClosedForNoIntersectionAndTie() {
        let first = MeetingExternalReferenceTrialADisplayCandidate(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let second = MeetingExternalReferenceTrialADisplayCandidate(
            displayID: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800))
        XCTAssertNil(MeetingExternalReferenceTrialADisplaySelector.selectDisplayID(
            windowFrame: CGRect(x: 3_000, y: 0, width: 100, height: 100), displays: [first, second]))
        XCTAssertNil(MeetingExternalReferenceTrialADisplaySelector.selectDisplayID(
            windowFrame: CGRect(x: 800, y: 100, width: 400, height: 400), displays: [first, second]))
    }

    func testTrialAWindowSelectionUsesOwningWindowAuthorityAcrossDuplicateAppRecords() {
        let staleRecordWindow = MeetingExternalReferenceTrialAWindowCandidate(
            windowID: 1, owningBundleIdentifier: "com.google.Chrome", owningProcessID: 101,
            title: "FluidVoice C2 Diagnostic Stimulus — READY")
        let playingWindow = MeetingExternalReferenceTrialAWindowCandidate(
            windowID: 2, owningBundleIdentifier: "com.google.Chrome", owningProcessID: 202,
            title: "FluidVoice C2 Diagnostic Stimulus — PLAYING")
        let selected = MeetingExternalReferenceTrialAWindowSelector.selectPlayingWindow(
            from: [staleRecordWindow, playingWindow], targetBundleIdentifier: "com.google.Chrome")
        XCTAssertEqual(selected?.windowID, 2)
        XCTAssertEqual(selected?.owningProcessID, 202)
    }

    func testTrialAWindowSelectionFailsClosedForDuplicatePlayingWindowsOrWrongOwner() {
        let first = MeetingExternalReferenceTrialAWindowCandidate(
            windowID: 1, owningBundleIdentifier: "com.google.Chrome", owningProcessID: 101,
            title: "FluidVoice C2 Diagnostic Stimulus — PLAYING")
        let second = MeetingExternalReferenceTrialAWindowCandidate(
            windowID: 2, owningBundleIdentifier: "com.google.Chrome", owningProcessID: 202,
            title: "FluidVoice C2 Diagnostic Stimulus — PLAYING")
        XCTAssertNil(MeetingExternalReferenceTrialAWindowSelector.selectPlayingWindow(
            from: [first, second], targetBundleIdentifier: "com.google.Chrome"))
        let wrongOwner = MeetingExternalReferenceTrialAWindowCandidate(
            windowID: 3, owningBundleIdentifier: "com.apple.Safari", owningProcessID: 303,
            title: "FluidVoice C2 Diagnostic Stimulus — PLAYING")
        XCTAssertNil(MeetingExternalReferenceTrialAWindowSelector.selectPlayingWindow(
            from: [wrongOwner], targetBundleIdentifier: "com.google.Chrome"))
    }

    func testTrialAOfflineAnalyzerRejectsGapsOverlapsSynthesizedAndBadGeometry() throws {
        func sample(_ pts: Double, _ duration: Double = 0.1, synthesized: Bool = false,
                    frames: Int = 4_800, arrival: Double? = nil) -> MeetingExternalReferenceTrialATrackSample {
            .init(presentationSeconds: pts, durationSeconds: duration, frameCount: frames,
                  sampleRateHz: 48_000, channelCount: 1, synthesizedTiming: synthesized,
                  rms: 0.05, peak: 0.08, arrivalSeconds: arrival)
        }
        let clean = MeetingExternalReferenceTrialAOfflineHarness.analyze(
            reference: [sample(0), sample(0.1), sample(0.2)],
            microphone: [sample(0), sample(0.1), sample(0.2)])
        XCTAssertFalse(clean.valid, "clock mapping is intentionally still unknown")
        XCTAssertFalse(clean.reference.timingValid, "three tenths of audio cannot cover a five-second request")
        XCTAssertEqual(clean.reference.coverageFraction, 0.06, accuracy: 0.000_001)
        XCTAssertFalse(clean.clock.sharedClockEstablished)
        XCTAssertNil(clean.clock.acousticDelaySeconds)

        let completeTiming = MeetingExternalReferenceTrialATrackReport.analyze(
            [sample(0), sample(0.1), sample(0.2)], requestedDurationSeconds: 0.3)
        XCTAssertTrue(completeTiming.timingValid)

        let ninetyFivePercent = MeetingExternalReferenceTrialATrackReport.analyze(
            (0..<19).map { sample(Double($0) * 0.1) }, requestedDurationSeconds: 2.0)
        XCTAssertEqual(ninetyFivePercent.coverageFraction, 0.95, accuracy: 0.000_001)
        XCTAssertFalse(ninetyFivePercent.timingValid, "95% coverage is not complete capture")

        let shiftedArrival = MeetingExternalReferenceTrialATrackReport.analyze(
            [sample(0, arrival: 10), sample(0.1, arrival: 10.1), sample(0.2, arrival: 10.2)],
            requestedDurationSeconds: 0.3,
            captureOpenArrivalSeconds: 0,
            captureCloseArrivalSeconds: 0.3)
        XCTAssertFalse(shiftedArrival.arrivalBoundaryValid)
        XCTAssertFalse(shiftedArrival.timingValid)

        let missingArrival = MeetingExternalReferenceTrialATrackReport.analyze(
            [sample(0), sample(0.1), sample(0.2)],
            requestedDurationSeconds: 0.3,
            captureOpenArrivalSeconds: 0,
            captureCloseArrivalSeconds: 0.3)
        XCTAssertFalse(missingArrival.arrivalBoundaryValid)
        XCTAssertFalse(missingArrival.timingValid)

        let boundedArrival = MeetingExternalReferenceTrialATrackReport.analyze(
            [sample(0, arrival: 0.01), sample(0.1, arrival: 0.11), sample(0.2, arrival: 0.21)],
            requestedDurationSeconds: 0.3,
            captureOpenArrivalSeconds: 0,
            captureCloseArrivalSeconds: 0.3)
        XCTAssertTrue(boundedArrival.arrivalBoundaryValid)
        XCTAssertTrue(boundedArrival.timingValid)

        let invalid = MeetingExternalReferenceTrialATrackReport.analyze(
            [sample(0), sample(0.2), sample(0.15, synthesized: true), sample(.nan), sample(0.3, frames: 1)],
            requestedDurationSeconds: 0.3)
        XCTAssertEqual(invalid.gapCount, 1)
        XCTAssertEqual(invalid.overlapCount, 1)
        XCTAssertEqual(invalid.synthesizedFrameCount, 4_800)
        XCTAssertEqual(invalid.invalidTimestampCount, 2)
        XCTAssertFalse(invalid.timingValid)
    }

    func testTrialAReportIsNumericOnlyAndNoPlaybackOrRetention() throws {
        let sample = MeetingExternalReferenceTrialATrackSample(
            presentationSeconds: 0, durationSeconds: 0.1, frameCount: 4_800,
            sampleRateHz: 48_000, channelCount: 1, synthesizedTiming: false,
            rms: 0.05, peak: 0.08)
        let report = MeetingExternalReferenceTrialAOfflineHarness.analyze(
            reference: [sample], microphone: [sample])
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["appOwnedPlayback"] as? Bool, false)
        XCTAssertEqual(object["rawPCMRetained"] as? Bool, false)
        XCTAssertEqual(object["transcriptRetained"] as? Bool, false)
        XCTAssertEqual(object["persisted"] as? Bool, false)
        XCTAssertEqual(object["captureValid"] as? Bool, false)
        XCTAssertEqual(object["acousticMeasurementValid"] as? Bool, false)
        XCTAssertNil(object["samples"])
        XCTAssertNil(object["pcm"])
    }
}

#endif
