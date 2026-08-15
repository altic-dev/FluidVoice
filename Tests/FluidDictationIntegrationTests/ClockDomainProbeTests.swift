@testable import FluidVoice_Debug
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest

/// Phase 0 of the mic-capture migration: is SCStream's audio PTS in the mach host clock domain?
///
/// The migration puts the microphone on AVAudioEngine, whose tap stamps are mach host time by
/// definition. Whether cross-track alignment needs a constant offset or a drift model depends
/// entirely on SCStream's clock: regress its audio PTS against mach time over a long capture and
/// read the slope. Arrival jitter perturbs individual samples, not a long-run slope.
///
/// Gate (MIC_CAPTURE_MIGRATION_PLAN.md §9): |slope − 1| < 20 ppm ⇒ constant offset is acceptable;
/// ≥ 20 ppm ⇒ the linear model in §8 is mandatory.
///
/// Run with FLUIDVOICE_CLOCK_PROBE=<minutes>.
final class ClockDomainProbeTests: XCTestCase {
    func testScreenCaptureAudioClockAgainstMachHostTime() async throws {
        guard let minutesString = ProcessInfo.processInfo.environment["FLUIDVOICE_CLOCK_PROBE"],
              let minutes = Double(minutesString), minutes > 0
        else {
            throw XCTSkip("FLUIDVOICE_CLOCK_PROBE not set")
        }

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

        let recorder = ClockPairRecorder()
        let output = ClockProbeOutput(recorder: recorder)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "clock.probe"))
        try await stream.startCapture()
        defer { Task { try? await stream.stopCapture() } }

        let seconds = minutes * 60
        print(String(format: "[clock] capturing for %.0f minutes…", minutes))
        // Progress report every minute so a truncated run still yields a usable slope series.
        var elapsed = 0.0
        while elapsed < seconds {
            let step = min(60.0, seconds - elapsed)
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            elapsed += step
            if let fit = await recorder.regression() {
                print(String(
                    format: "[clock] t=%4.0fs n=%6d slope=%+.3f ppm  residualStd=%.3f ms  ptsSpan=%.1fs",
                    elapsed, fit.count, fit.slopePPM, fit.residualStdMs, fit.ptsSpanSeconds
                ))
            }
        }

        guard let fit = await recorder.regression(), fit.count > 1000 else {
            XCTFail("insufficient samples for a slope estimate")
            return
        }
        print(String(
            format: "\n[clock] FINAL n=%d slope=%+.3f ppm (95%% CI ±%.3f)  residualStd=%.3f ms  gate=%@",
            fit.count, fit.slopePPM, fit.slopeCI95PPM, fit.residualStdMs,
            abs(fit.slopePPM) < 20 ? "CONSTANT OFFSET OK" : "LINEAR MODEL REQUIRED"
        ))
    }
}

/// Records (mach seconds, SCStream PTS seconds) pairs and fits PTS = a + b·mach by least squares.
private actor ClockPairRecorder {
    struct Fit {
        let count: Int
        let slopePPM: Double
        let slopeCI95PPM: Double
        let residualStdMs: Double
        let ptsSpanSeconds: Double
    }

    private var machTimes: [Double] = []
    private var ptsTimes: [Double] = []

    func record(mach: Double, pts: Double) {
        self.machTimes.append(mach)
        self.ptsTimes.append(pts)
    }

    func regression() -> Fit? {
        let n = self.machTimes.count
        guard n > 10 else { return nil }
        let x0 = self.machTimes[0]
        let y0 = self.ptsTimes[0]
        let xs = self.machTimes.map { $0 - x0 }
        let ys = self.ptsTimes.map { $0 - y0 }
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let meanX = sumX / Double(n)
        let meanY = sumY / Double(n)
        var sxx = 0.0
        var sxy = 0.0
        for i in 0..<n {
            let dx = xs[i] - meanX
            sxx += dx * dx
            sxy += dx * (ys[i] - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        var sse = 0.0
        let intercept = meanY - slope * meanX
        for i in 0..<n {
            let r = ys[i] - (intercept + slope * xs[i])
            sse += r * r
        }
        let residualVariance = sse / Double(max(1, n - 2))
        let slopeStdErr = (residualVariance / sxx).squareRoot()
        return Fit(
            count: n,
            slopePPM: (slope - 1) * 1_000_000,
            slopeCI95PPM: 1.96 * slopeStdErr * 1_000_000,
            residualStdMs: residualVariance.squareRoot() * 1_000,
            ptsSpanSeconds: ys.last ?? 0
        )
    }
}

private final class ClockProbeOutput: NSObject, SCStreamOutput {
    private let recorder: ClockPairRecorder
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    init(recorder: ClockPairRecorder) { self.recorder = recorder }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        let mach = Double(mach_absolute_time()) * Self.timebase
        let seconds = pts.seconds
        Task { [recorder] in await recorder.record(mach: mach, pts: seconds) }
    }
}
