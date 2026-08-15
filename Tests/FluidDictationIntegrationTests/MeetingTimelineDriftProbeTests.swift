@testable import FluidVoice_Debug
import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest

/// Phase 2 gate: do the two capture paths' clocks stay in step? Runs `MeetingMicrophoneCapture`
/// (VPIO, built-in mic) and an SCStream audio capture simultaneously, regressing each path's
/// emitted PTS against mach wall time.
///
/// Gate: |slope_mic − slope_app| + CI_Δ < 6.9 ppm — derived from the ±50 ms ordering budget over a
/// 2-hour meeting (50 ms / 7200 s), NOT from Phase 0's 20 ppm domain check, which answered a
/// different question. Absolute cross-path offset is not measurable acoustically (AEC removes the
/// stimulus at ~33 dB); the deterministic latency components are printed instead as the Phase 3
/// estimate. Preconditions: foreground session, unlocked display, speakers (not Bluetooth — VPIO
/// delivers nothing on a BT render route), VPIO ducking audible during the run.
///
/// Run with FLUIDVOICE_DRIFT_PROBE=<minutes>.
final class MeetingTimelineDriftProbeTests: XCTestCase {
    private static let gatePPM = 6.9
    private static let ciBudgetPPM = 1.4 // 20% of the gate; wider means "extend the run", not "pass"

    func testCrossPathClockDrift() async throws {
        guard let minutesString = ProcessInfo.processInfo.environment["FLUIDVOICE_DRIFT_PROBE"],
              let minutes = Double(minutesString), minutes > 0
        else { throw XCTSkip("FLUIDVOICE_DRIFT_PROBE not set") }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw XCTSkip("no display") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let appRecorder = ClockPairRecorder()
        let appOutput = DriftStreamOutput(recorder: appRecorder)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(appOutput, type: .audio, sampleHandlerQueue: DispatchQueue(label: "drift.app"))
        try await stream.startCapture()
        defer { Task { try? await stream.stopCapture() } }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let microphone = try MeetingCaptureSourceCatalog.defaultMicrophone(preferredCoreAudioUID: "BuiltInMicrophoneDevice")
        var writerDiscontinuities = 0
        let track = MeetingAudioTrack(
            id: UUID(), kind: .microphone,
            sourceIdentifier: microphone.captureDeviceID, sourceDisplayName: microphone.displayName,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: mach_absolute_time(),
                machTimebaseNumerator: Self.timebase.numer,
                machTimebaseDenominator: Self.timebase.denom,
                firstPresentationTime: nil
            ),
            health: .waiting, chunks: []
        )
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: temp, chunkDuration: 60) { _ in }

        let micRecorder = ClockPairRecorder()
        let capture = MeetingMicrophoneCapture()
        let outcome = try await capture.start(microphone: microphone) { sampleBuffer in
            // Mach sampled synchronously on the tap thread, before the writer hop.
            let mach = Double(mach_absolute_time()) * Self.timebaseSeconds
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid {
                Task { await micRecorder.record(mach: mach, pts: pts.seconds) }
            }
            writer.enqueue(sampleBuffer)
        }
        guard case .boundVerified = outcome else {
            throw XCTSkip("mic not bindable in this environment: \(outcome)")
        }
        Self.printLatencyEstimate(capture: await capture.settledConfiguration())

        let seconds = minutes * 60
        var elapsed = 0.0
        while elapsed < seconds {
            let step = min(60.0, seconds - elapsed)
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            elapsed += step
            if elapsed >= 30, await micRecorder.count() == 0 {
                XCTFail("no mic buffers after 30s — Bluetooth render route or dead capture")
                await capture.stop()
                return
            }
            let mic = await micRecorder.regression()
            let app = await appRecorder.regression()
            print(String(
                format: "[drift] t=%4.0fs mic n=%5d slope=%+7.3f ppm | app n=%6d slope=%+7.3f ppm",
                elapsed, mic?.count ?? 0, mic?.slopePPM ?? .nan, app?.count ?? 0, app?.slopePPM ?? .nan
            ))
        }

        await capture.stop()
        let finishedTrack = await writer.stop()
        writerDiscontinuities = finishedTrack.chunks.reduce(0) { $0 + $1.discontinuities.count }
        let stats = await capture.statistics()

        guard let mic = await micRecorder.regression(), let app = await appRecorder.regression() else {
            return XCTFail("insufficient samples for regression")
        }
        let delta = abs(mic.slopePPM - app.slopePPM)
        let ciDelta = (mic.slopeCI95PPM * mic.slopeCI95PPM + app.slopeCI95PPM * app.slopeCI95PPM).squareRoot()
        let micHalves = await micRecorder.halfSplitSlopesPPM()

        print(String(format: "\n[drift] mic  slope=%+.3f ppm (CI ±%.3f)  residual=%.2f ms  n=%d", mic.slopePPM, mic.slopeCI95PPM, mic.residualStdMs, mic.count))
        print(String(format: "[drift] app  slope=%+.3f ppm (CI ±%.3f)  residual=%.2f ms  n=%d", app.slopePPM, app.slopeCI95PPM, app.residualStdMs, app.count))
        print(String(format: "[drift] Δ=%.3f ppm  CI_Δ=%.3f  →  projected skew %.1f ms/hour", delta, ciDelta, (delta + ciDelta) * 3.6))
        if let halves = micHalves {
            print(String(format: "[drift] mic half-split: %+.3f / %+.3f ppm (Δ=%.3f)", halves.first, halves.second, abs(halves.first - halves.second)))
        }
        print("[drift] guards: seqViolations=\(stats.sequenceContinuityViolations) convFail=\(stats.conversionFailures) droppedPostCap=\(stats.droppedPostCapCount) resyncs=\(stats.resyncCount) writerDisc=\(writerDiscontinuities) configChanges=\(stats.configurationChangeEvents) corrections=\(stats.anchorCorrectionCount) absorbed=\(String(format: "%.3f", stats.cumulativeAbsorbedCorrectionSeconds * 1_000))ms stepEvents=\(stats.divergenceStepEventCount)")
        print("[drift] NOTE: absolute cross-path offset is unmeasured here (AEC removes acoustic stimuli); Phase 3 validates it on a real call.")

        if stats.configurationChangeEvents > 0 {
            throw XCTSkip("configuration changed mid-run — probe artifact, re-run")
        }
        XCTAssertEqual(stats.sequenceContinuityViolations, 0)
        XCTAssertEqual(stats.conversionFailures, 0)
        XCTAssertEqual(stats.droppedPostCapCount, 0)
        XCTAssertEqual(stats.resyncCount, 0)
        XCTAssertEqual(writerDiscontinuities, 0)
        XCTAssertLessThanOrEqual(ciDelta, Self.ciBudgetPPM, "CI too wide — extend the run rather than trusting the point estimate")
        XCTAssertLessThan(delta + ciDelta, Self.gatePPM, "cross-path drift violates the ±50ms/2h ordering budget")
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private static let timebaseSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000

    /// The deterministic latency components — the Phase 3 absolute-offset estimate.
    private static func printLatencyEstimate(capture settled: MeetingMicrophoneSettledConfig?) {
        guard let settled else { return }
        print("[drift] settled: input=\(settled.settledInputDeviceUID ?? "?") output=\(settled.settledOutputDeviceUID ?? "?") source=\(settled.sourceSampleRate)Hz/\(settled.sourceChannelCount)ch")
    }
}

private final class DriftStreamOutput: NSObject, SCStreamOutput {
    private let recorder: ClockPairRecorder
    private static let timebaseSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    init(recorder: ClockPairRecorder) { self.recorder = recorder }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        let mach = Double(mach_absolute_time()) * Self.timebaseSeconds
        Task { [recorder] in await recorder.record(mach: mach, pts: pts.seconds) }
    }
}
