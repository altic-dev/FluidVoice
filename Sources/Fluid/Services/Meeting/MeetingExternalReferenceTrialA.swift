#if DEBUG

import AppKit
import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

/// Trial A is intentionally a separate gate from C2 and Trial B. It captures only the selected
/// Chrome audio as a reference and the existing VPIO microphone as capture; it never renders audio,
/// transcribes, persists, or changes the production route.
nonisolated enum MeetingExternalReferenceTrialAGate {
    static let environmentKey = "FLUIDVOICE_TRIAL_A"
    static let targetBundleIDEnvironmentKey = "FLUIDVOICE_TRIAL_A_TARGET_BUNDLE_ID"
    static let autorunEnvironmentKey = "FLUIDVOICE_TRIAL_A_AUTORUN"
    static let requiredTargetBundleID = "com.google.Chrome"
    /// The localhost fixture changes its document title only after the user has clicked Start and
    /// while its AudioContext is active. Checking this title prevents a run from spending its one
    /// audited capture window on a merely-open (or already-complete) browser tab.
    static let stimulusWindowTitleMarker = "FluidVoice C2 Diagnostic Stimulus"
    static let stimulusWindowPlayingMarker = "PLAYING"

    static func enabled(environment: [String: String]) -> Bool {
        environment[Self.environmentKey] == "1"
            && environment[Self.targetBundleIDEnvironmentKey] == Self.requiredTargetBundleID
    }

    static func autorunEnabled(environment: [String: String]) -> Bool {
        self.enabled(environment: environment) && environment[Self.autorunEnvironmentKey] == "1"
    }

    static func stimulusWindowIsPlaying(title: String?) -> Bool {
        guard let title else { return false }
        let prefix = "\(Self.stimulusWindowTitleMarker) — \(Self.stimulusWindowPlayingMarker)"
        guard title.hasPrefix(prefix) else { return false }
        let suffix = title.dropFirst(prefix.count)
        // Chrome may append its product name, but a state token must end at a title boundary;
        // reject strings such as "NOT PLAYING" and "PLAYINGISH".
        return suffix.isEmpty || suffix.hasPrefix(" - ") || suffix.hasPrefix(" — ")
    }
}

nonisolated struct MeetingExternalReferenceTrialADisplayCandidate: Equatable, Sendable {
    let displayID: UInt32
    let frame: CGRect
}

nonisolated struct MeetingExternalReferenceTrialAWindowCandidate: Equatable, Sendable {
    let windowID: UInt32
    let owningBundleIdentifier: String?
    let owningProcessID: Int32
    let title: String?
}

nonisolated enum MeetingExternalReferenceTrialAWindowSelector {
    /// The owning window is the source of truth for readiness. Application lists can contain
    /// duplicate/stale records for one bundle, so selecting an arbitrary bundle record first can
    /// make a real PLAYING window look absent.
    static func selectPlayingWindow(
        from windows: [MeetingExternalReferenceTrialAWindowCandidate],
        targetBundleIdentifier: String
    ) -> MeetingExternalReferenceTrialAWindowCandidate? {
        let matches = windows.filter {
            $0.owningBundleIdentifier == targetBundleIdentifier
                && $0.owningProcessID > 0
                && MeetingExternalReferenceTrialAGate.stimulusWindowIsPlaying(title: $0.title)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

nonisolated enum MeetingExternalReferenceTrialADisplaySelector {
    /// Selects the display containing the matched stimulus window. A zero-area intersection or a
    /// tie is ambiguous and fails closed; choosing `displays.first` can silently capture the wrong
    /// display on a multi-monitor desktop.
    static func selectDisplayID(
        windowFrame: CGRect,
        displays: [MeetingExternalReferenceTrialADisplayCandidate]
    ) -> UInt32? {
        let intersections = displays.compactMap { display -> (id: UInt32, area: CGFloat)? in
            let intersection = display.frame.intersection(windowFrame)
            let area = intersection.width * intersection.height
            guard area > 0, area.isFinite else { return nil }
            return (display.displayID, area)
        }
        guard let maximum = intersections.map(\.area).max(), maximum > 0 else { return nil }
        let winners = intersections.filter { $0.area == maximum }
        guard winners.count == 1 else { return nil }
        return winners[0].id
    }
}

nonisolated struct MeetingExternalReferenceTrialATrackSample: Equatable, Sendable {
    let presentationSeconds: Double
    let durationSeconds: Double
    let frameCount: Int
    let sampleRateHz: Double
    let channelCount: Int
    let synthesizedTiming: Bool
    let rms: Double
    let peak: Double
    /// Monotonic callback-delivery time. Offline fixtures may omit this; live captures record it
    /// to prove samples belong to the bounded capture-open/close window.
    let arrivalSeconds: Double?

    init(
        presentationSeconds: Double,
        durationSeconds: Double,
        frameCount: Int,
        sampleRateHz: Double,
        channelCount: Int,
        synthesizedTiming: Bool,
        rms: Double,
        peak: Double,
        arrivalSeconds: Double? = nil
    ) {
        self.presentationSeconds = presentationSeconds
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.synthesizedTiming = synthesizedTiming
        self.rms = rms
        self.peak = peak
        self.arrivalSeconds = arrivalSeconds
    }
}

nonisolated struct MeetingExternalReferenceTrialATrackReport: Codable, Equatable, Sendable {
    let callbackCount: Int
    let droppedFrameCount: Int
    let validSampleCount: Int
    let invalidTimestampCount: Int
    let firstPresentationSeconds: Double?
    let lastPresentationEndSeconds: Double?
    let deliveredDurationSeconds: Double
    let coveredDurationSeconds: Double
    let coverageFraction: Double
    let gapCount: Int
    let gapDurationSeconds: Double
    let overlapCount: Int
    let overlapDurationSeconds: Double
    let backwardsTimestampCount: Int
    let synthesizedFrameCount: Int
    let formatChangeCount: Int
    let rms: Double?
    let peak: Double?
    let clippedSampleCount: Int
    let captureOpenArrivalSeconds: Double?
    let captureCloseArrivalSeconds: Double?
    let arrivalBoundaryValid: Bool
    let arrivalCoverageSeconds: Double?
    let timingValid: Bool

    static func analyze(
        _ samples: [MeetingExternalReferenceTrialATrackSample],
        requestedDurationSeconds: Double,
        droppedFrameCount: Int = 0,
        callbackCount: Int? = nil,
        captureOpenArrivalSeconds: Double? = nil,
        captureCloseArrivalSeconds: Double? = nil
    ) -> Self {
        let requested = requestedDurationSeconds.isFinite && requestedDurationSeconds > 0
            ? requestedDurationSeconds : 0
        var invalid = 0
        var clipped = 0
        var valid = [MeetingExternalReferenceTrialATrackSample]()
        for sample in samples {
            if sample.peak.isFinite && sample.peak > 1 { clipped += 1 }
            let validTiming = sample.presentationSeconds.isFinite && sample.presentationSeconds >= 0
                && sample.durationSeconds.isFinite && sample.durationSeconds > 0
                && (sample.presentationSeconds + sample.durationSeconds).isFinite
                && sample.frameCount > 0 && sample.sampleRateHz.isFinite && sample.sampleRateHz > 0
                && sample.channelCount > 0 && sample.rms.isFinite && sample.rms >= 0
                && sample.peak.isFinite && sample.peak >= 0 && sample.peak <= 1
                && abs(Double(sample.frameCount) / sample.sampleRateHz - sample.durationSeconds)
                    <= max(1.5 / sample.sampleRateHz, 0.001)
            if validTiming { valid.append(sample) } else { invalid += 1 }
        }
        var first: Double?
        var lastEnd: Double?
        var delivered = 0.0
        var covered = 0.0
        var gaps = 0
        var gapDuration = 0.0
        var overlaps = 0
        var overlapDuration = 0.0
        var backwards = 0
        var synthesized = 0
        var formats = Set<String>()
        var arrivals: [(time: Double, duration: Double)] = []
        var previousStart: Double?
        var previousEnd: Double?
        var previousSampleRate: Double?
        for sample in valid {
            let end = sample.presentationSeconds + sample.durationSeconds
            first = min(first ?? sample.presentationSeconds, sample.presentationSeconds)
            lastEnd = max(lastEnd ?? end, end)
            delivered += sample.durationSeconds
            formats.insert("\(sample.sampleRateHz):\(sample.channelCount)")
            if let arrival = sample.arrivalSeconds, arrival.isFinite {
                arrivals.append((arrival, sample.durationSeconds))
            }
            if sample.synthesizedTiming { synthesized += sample.frameCount }
            if let previousStart, let previousEnd {
                let continuityTolerance = max(
                    1e-9,
                    0.5 / min(previousSampleRate ?? sample.sampleRateHz, sample.sampleRateHz)
                )
                if sample.presentationSeconds < previousStart - continuityTolerance { backwards += 1 }
                if sample.presentationSeconds > previousEnd + continuityTolerance {
                    gaps += 1
                    gapDuration += sample.presentationSeconds - previousEnd
                } else if sample.presentationSeconds < previousEnd - continuityTolerance {
                    overlaps += 1
                    overlapDuration += previousEnd - sample.presentationSeconds
                }
                // Union coverage counts audio intervals only; a gap is reported separately and
                // must never inflate the covered fraction.
                covered += sample.presentationSeconds >= previousEnd
                    ? sample.durationSeconds
                    : max(0, end - previousEnd)
            } else {
                covered += sample.durationSeconds
            }
            previousStart = sample.presentationSeconds
            previousEnd = max(previousEnd ?? end, end)
            previousSampleRate = sample.sampleRateHz
        }
        let coverage = requested > 0 ? min(1, max(0, covered / requested)) : 0
        let oneSourceSampleSeconds = valid.map { 1 / $0.sampleRateHz }.min() ?? 0
        let hasExplicitArrivalWindow = captureOpenArrivalSeconds != nil
            || captureCloseArrivalSeconds != nil
        let hasArrivalEvidence = captureOpenArrivalSeconds?.isFinite == true
            && captureCloseArrivalSeconds?.isFinite == true
            && arrivals.count == valid.count
        let sortedArrivals = arrivals.sorted { $0.time < $1.time }
        let arrivalCoverage: Double? = hasArrivalEvidence
            ? sortedArrivals.first.flatMap { first in
                sortedArrivals.last.map { last in
                    max(0, last.time - first.time + last.duration)
                }
            } : nil
        let boundaryTolerance = arrivals.map(\.duration).max() ?? oneSourceSampleSeconds
        let arrivalBoundaryValid = !hasExplicitArrivalWindow || (hasArrivalEvidence && {
            guard let open = captureOpenArrivalSeconds, let close = captureCloseArrivalSeconds,
                  let arrivalCoverage else { return false }
            let allWithinWindow = arrivals.allSatisfy {
                $0.time >= open - boundaryTolerance && $0.time <= close + boundaryTolerance
            }
            return allWithinWindow && arrivalCoverage + boundaryTolerance >= requested
        }())
        let rms = valid.isEmpty ? nil : sqrt(valid.reduce(0.0) { $0 + $1.rms * $1.rms } / Double(valid.count))
        let peak = valid.map(\.peak).max()
        let timingValid = !valid.isEmpty && droppedFrameCount == 0 && invalid == 0 && clipped == 0 && gaps == 0 && overlaps == 0
            && backwards == 0 && synthesized == 0 && formats.count <= 1
            // Complete means the requested interval is covered, with only one source-sample of
            // floating-point/frame-quantization tolerance. A broad percentage threshold would
            // incorrectly accept materially truncated captures.
            && coverage + oneSourceSampleSeconds / max(requested, 1) >= 1.0
            && arrivalBoundaryValid
        return Self(
            callbackCount: max(samples.count, callbackCount ?? samples.count),
            droppedFrameCount: max(0, droppedFrameCount),
            validSampleCount: valid.count,
            invalidTimestampCount: invalid,
            firstPresentationSeconds: first,
            lastPresentationEndSeconds: lastEnd,
            deliveredDurationSeconds: delivered,
            coveredDurationSeconds: covered,
            coverageFraction: coverage,
            gapCount: gaps,
            gapDurationSeconds: gapDuration,
            overlapCount: overlaps,
            overlapDurationSeconds: overlapDuration,
            backwardsTimestampCount: backwards,
            synthesizedFrameCount: synthesized,
            formatChangeCount: max(0, formats.count - 1),
            rms: rms,
            peak: peak,
            clippedSampleCount: clipped,
            captureOpenArrivalSeconds: captureOpenArrivalSeconds,
            captureCloseArrivalSeconds: captureCloseArrivalSeconds,
            arrivalBoundaryValid: arrivalBoundaryValid,
            arrivalCoverageSeconds: arrivalCoverage,
            timingValid: timingValid
        )
    }
}

nonisolated struct MeetingExternalReferenceTrialAClockReport: Codable, Equatable, Sendable {
    let sharedClockEstablished: Bool
    let acousticDelaySeconds: Double?
    let relationship: String
    let reason: String
}

nonisolated struct MeetingExternalReferenceTrialAReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    let schemaVersion: Int
    let targetBundleID: String
    let targetProcessID: Int32
    let targetProcessStable: Bool
    let selectionConfirmed: Bool
    let microphoneDeviceID: UInt32?
    let defaultInputDeviceID: UInt32?
    let outputDeviceID: UInt32?
    let defaultOutputDeviceID: UInt32?
    let builtInRouteConfirmed: Bool
    let postCaptureRouteConfirmed: Bool
    let outputVolume: Double?
    let postCaptureOutputVolume: Double?
    let outputVolumeReadable: Bool
    let outputVolumeUnchanged: Bool
    let combinedPeakBound: Double?
    let measuredCombinedPeak: Double?
    let referenceExcitationConfirmed: Bool
    let streamErrorCount: Int
    let stopErrorCount: Int
    let reference: MeetingExternalReferenceTrialATrackReport
    let microphone: MeetingExternalReferenceTrialATrackReport
    let clock: MeetingExternalReferenceTrialAClockReport
    let voiceProcessingReadback: MeetingVoiceProcessingProbeSnapshot?
    let appOwnedPlayback: Bool
    let rawPCMRetained: Bool
    let transcriptRetained: Bool
    let persisted: Bool
    let captureValid: Bool
    let acousticMeasurementValid: Bool
    let reasons: [String]

    /// Backward-compatible summary used by the offline diagnostic tests. Trial A can report
    /// capture health while remaining invalid as an acoustic measurement until clock mapping is
    /// established.
    var valid: Bool { acousticMeasurementValid }
}

/// Lock-protected PCM collector. `reportAndRelease` computes numbers and then drops every sample
/// buffer before returning, so only numeric metadata crosses the diagnostic process boundary.
final nonisolated class MeetingExternalReferenceTrialACollector: @unchecked Sendable {
    private let lock = NSLock()
    // Keep a bounded six-second headroom. ScreenCaptureKit may deliver a small trailing tail
    // after a five-second wall-clock capture; treating that tail as a drop made every healthy
    // paired capture invalid while still retaining a strict memory bound.
    private let maximumFrames = 288_000 // 6 seconds at 48 kHz per track
    private var retainedFrames = 0
    private var callbackCount = 0
    private var droppedFrameCount = 0
    private var captureOpenArrivalSeconds: Double?
    private var captureCloseArrivalSeconds: Double?
    private var samples: [MeetingExternalReferenceTrialATrackSample] = []
    private var pcm: [[Float]] = []

    func ingest(_ sampleBuffer: CMSampleBuffer, synthesizedTiming: Bool = false) {
        self.lock.lock()
        self.callbackCount += 1
        self.lock.unlock()
        let arrival = ProcessInfo.processInfo.systemUptime
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        let callbackFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let copied = MeetingLiveSampleCopy.copy(sampleBuffer),
              let channel = copied.buffer.floatChannelData?[0] else {
            self.lock.lock(); defer { self.lock.unlock() }
            self.samples.append(.init(presentationSeconds: pts, durationSeconds: duration,
                                      frameCount: callbackFrames, sampleRateHz: .nan,
                                      channelCount: 0, synthesizedTiming: synthesizedTiming,
                                      rms: .nan, peak: .nan, arrivalSeconds: arrival))
            return
        }
        let frameCount = Int(copied.buffer.frameLength)
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(frameCount))
        var sum: Float = 0
        vDSP_svesq(channel, 1, &sum, vDSP_Length(frameCount))
        let rms = frameCount > 0 ? sqrt(Double(sum) / Double(frameCount)) : .nan
        let sample = MeetingExternalReferenceTrialATrackSample(
            presentationSeconds: pts, durationSeconds: duration, frameCount: frameCount,
            sampleRateHz: copied.buffer.format.sampleRate,
            channelCount: Int(copied.buffer.format.channelCount),
            synthesizedTiming: synthesizedTiming, rms: rms, peak: Double(peak), arrivalSeconds: arrival)
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.retainedFrames + frameCount <= self.maximumFrames else {
            self.droppedFrameCount += frameCount
            return
        }
        self.retainedFrames += frameCount
        self.samples.append(sample)
        self.pcm.append(Array(UnsafeBufferPointer(start: channel, count: frameCount)))
    }

    func reportAndRelease(requestedDurationSeconds: Double) -> MeetingExternalReferenceTrialATrackReport {
        self.lock.lock()
        let open = self.captureOpenArrivalSeconds
        let close = self.captureCloseArrivalSeconds
        let samples = self.samples
        let droppedFrameCount = self.droppedFrameCount
        let callbackCount = self.callbackCount
        self.samples.removeAll(keepingCapacity: false)
        self.pcm.removeAll(keepingCapacity: false)
        self.retainedFrames = 0
        self.droppedFrameCount = 0
        self.callbackCount = 0
        self.captureOpenArrivalSeconds = nil
        self.captureCloseArrivalSeconds = nil
        self.lock.unlock()
        return MeetingExternalReferenceTrialATrackReport.analyze(
            samples, requestedDurationSeconds: requestedDurationSeconds,
            droppedFrameCount: droppedFrameCount, callbackCount: callbackCount,
            captureOpenArrivalSeconds: open, captureCloseArrivalSeconds: close)
    }

    func reset() {
        self.lock.lock()
        self.samples.removeAll(keepingCapacity: false)
        self.pcm.removeAll(keepingCapacity: false)
        self.retainedFrames = 0
        self.droppedFrameCount = 0
        self.callbackCount = 0
        self.captureOpenArrivalSeconds = ProcessInfo.processInfo.systemUptime
        self.captureCloseArrivalSeconds = nil
        self.lock.unlock()
    }

    func markCaptureClosed() {
        self.lock.lock()
        self.captureCloseArrivalSeconds = ProcessInfo.processInfo.systemUptime
        self.lock.unlock()
    }
}

nonisolated enum MeetingExternalReferenceTrialAOfflineHarness {
    static func analyze(
        reference: [MeetingExternalReferenceTrialATrackSample],
        microphone: [MeetingExternalReferenceTrialATrackSample],
        requestedDurationSeconds: Double = 5
    ) -> MeetingExternalReferenceTrialAReport {
        let referenceReport = MeetingExternalReferenceTrialATrackReport.analyze(
            reference, requestedDurationSeconds: requestedDurationSeconds)
        let microphoneReport = MeetingExternalReferenceTrialATrackReport.analyze(
            microphone, requestedDurationSeconds: requestedDurationSeconds)
        let clock = MeetingExternalReferenceTrialAClockReport(
            sharedClockEstablished: false, acousticDelaySeconds: nil,
            relationship: "independent PTS origins; no defensible clock mapping",
            reason: "acoustic delay and AEC measurement are unknown")
        return MeetingExternalReferenceTrialAReport(
            schemaVersion: MeetingExternalReferenceTrialAReport.currentSchemaVersion,
            targetBundleID: MeetingExternalReferenceTrialAGate.requiredTargetBundleID,
            targetProcessID: 0, targetProcessStable: false,
            selectionConfirmed: false,
            microphoneDeviceID: nil, defaultInputDeviceID: nil,
            outputDeviceID: nil, defaultOutputDeviceID: nil,
            builtInRouteConfirmed: false,
            postCaptureRouteConfirmed: false, outputVolume: nil,
            postCaptureOutputVolume: nil,
            outputVolumeReadable: false, outputVolumeUnchanged: false,
            combinedPeakBound: nil, measuredCombinedPeak: nil,
            referenceExcitationConfirmed: false,
            streamErrorCount: 0,
            stopErrorCount: 0,
            reference: referenceReport, microphone: microphoneReport, clock: clock,
            voiceProcessingReadback: nil,
            appOwnedPlayback: false, rawPCMRetained: false,
            transcriptRetained: false, persisted: false,
            captureValid: false, acousticMeasurementValid: false,
            reasons: ["offline harness", "independent clocks; result is unknown"])
    }
}

nonisolated enum MeetingExternalReferenceTrialAAutorun {
    static let captureDurationSeconds = 5.0
    static let maximumRunSeconds = 12.0
    static let hardWatchdogSeconds = 14.0
    private static let operationTimeoutSeconds = 2.0

    @discardableResult
    static func startIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard MeetingExternalReferenceTrialAGate.autorunEnabled(environment: environment) else {
            return false
        }
        let gate = CompletionGate()
        let watchdog = DispatchWorkItem {
            guard gate.claim() else { return }
            print("[TRIAL_A_AUTORUN] {\"exitStatus\":1,\"reason\":\"hard timeout\",\"status\":\"failure\"}")
            fflush(stdout)
            Darwin.exit(1)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Self.hardWatchdogSeconds, execute: watchdog)
        Task { @MainActor in
            let outcome: Outcome
            do {
                outcome = try await Self.withTimeout(seconds: Self.maximumRunSeconds) {
                    await Self.run(environment: environment)
                }
            } catch {
                outcome = Self.failure("Trial A timed out or was cancelled")
            }
            watchdog.cancel()
            guard gate.claim() else { return }
            print("[TRIAL_A_AUTORUN] " + outcome.line)
            fflush(stdout)
            Darwin.exit(outcome.exitStatus)
        }
        return true
    }

    private struct Outcome: Sendable { let exitStatus: Int32; let line: String }
    private enum RunError: Error { case timeout }
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !done else { return false }; done = true; return true }
    }

    @MainActor
    private static func run(environment: [String: String]) async -> Outcome {
        guard CGPreflightScreenCaptureAccess() else { return Self.failure("screen recording access is not authorized") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return Self.failure("microphone access is not authorized") }
        guard let targetBundleID = environment[MeetingExternalReferenceTrialAGate.targetBundleIDEnvironmentKey],
              targetBundleID == MeetingExternalReferenceTrialAGate.requiredTargetBundleID else { return Self.failure("Trial A target must be Chrome") }

        guard let microphoneDevice = try? await MeetingCaptureSourceCatalog.defaultMicrophone(),
              let inputDevice = AudioDevice.listInputDevices().first(where: { $0.uid == microphoneDevice.coreAudioUID }),
              inputDevice.isAlive, inputDevice.isBuiltIn,
              AudioDevice.getDefaultInputDevice()?.uid == microphoneDevice.coreAudioUID else {
            return Self.failure("default live built-in microphone preflight failed")
        }
        let preRoute = MeetingCaptureEngine.currentOutputRouteSnapshot()
        guard MeetingCapturePathDecider.outputRouteDeclineReason(preRoute) == nil,
              let outputDevice = AudioDevice.getDefaultOutputDevice(), outputDevice.isAlive else {
            return Self.failure("default live built-in speaker preflight failed")
        }
        let volume = Self.readOutputVolume(outputDevice.id)
        let combinedPeakBound = volume.map { Double($0) * 0.08 }
        guard let volume, volume.isFinite, volume > 0, volume <= 0.6,
              let combinedPeakBound, combinedPeakBound <= 0.15 else {
            return Self.failure("output volume or combined peak safety preflight failed")
        }

        let content: SCShareableContent
        do { content = try await SCShareableContent.current } catch { return Self.failure("shareable content unavailable") }
        let windowCandidates = content.windows.compactMap { window -> MeetingExternalReferenceTrialAWindowCandidate? in
            guard let owner = window.owningApplication else { return nil }
            return MeetingExternalReferenceTrialAWindowCandidate(
                windowID: window.windowID,
                owningBundleIdentifier: owner.bundleIdentifier,
                owningProcessID: owner.processID,
                title: window.title)
        }
        guard let selectedWindow = MeetingExternalReferenceTrialAWindowSelector.selectPlayingWindow(
            from: windowCandidates, targetBundleIdentifier: targetBundleID),
              let stimulusWindow = content.windows.first(where: { $0.windowID == selectedWindow.windowID }),
              let application = stimulusWindow.owningApplication,
              application.bundleIdentifier == targetBundleID,
              application.processID > 0,
              NSRunningApplication(processIdentifier: application.processID)?.isTerminated == false else {
            return Self.failure("controlled Chrome PLAYING window is absent, stale, or ambiguous")
        }
        let displayCandidates = content.displays.map {
            MeetingExternalReferenceTrialADisplayCandidate(displayID: $0.displayID, frame: $0.frame)
        }
        guard let displayID = MeetingExternalReferenceTrialADisplaySelector.selectDisplayID(
            windowFrame: stimulusWindow.frame, displays: displayCandidates),
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return Self.failure("controlled Chrome stimulus window does not intersect exactly one display")
        }
        let referenceCollector = MeetingExternalReferenceTrialACollector()
        let microphoneCollector = MeetingExternalReferenceTrialACollector()
        let capture = MeetingMicrophoneCapture()
        var stream: SCStream?
        var streamOutput: TrialAStreamOutput?
        let streamDelegate = TrialAStreamDelegate()
        var stopErrorCount = 0
        do {
            _ = try await capture.start(
                microphone: microphoneDevice,
                authorizationPreflighted: true,
                onSample: { _ in },
                onSampleMetadata: { sampleBuffer, synthesized, _ in
                    microphoneCollector.ingest(sampleBuffer, synthesizedTiming: synthesized)
                })

            let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3; configuration.showsCursor = false
            configuration.capturesAudio = true; configuration.captureMicrophone = false
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000; configuration.channelCount = 2
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)
            // Publish before the async start so timeout/start failures can always stop and clean
            // up the stream that was created.
            stream = newStream
            let output = TrialAStreamOutput(collector: referenceCollector)
            streamOutput = output
            try newStream.addStreamOutput(
                output, type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "fluidvoice.trial-a.reference", qos: .userInteractive))
            try await Self.withTimeout(seconds: Self.operationTimeoutSeconds) { try await newStream.startCapture() }
            // VPIO must start first to establish its hardware graph, but only samples after this
            // shared capture-open boundary belong to Trial A's bounded five-second window.
            referenceCollector.reset()
            microphoneCollector.reset()
            try await Task.sleep(nanoseconds: UInt64(Self.captureDurationSeconds * 1_000_000_000))
            try Task.checkCancellation()
        } catch {
            if let stream {
                do { try await Self.withTimeout(seconds: Self.operationTimeoutSeconds) { try await stream.stopCapture() } }
                catch { stopErrorCount += 1 }
                if let streamOutput { try? await stream.removeStreamOutput(streamOutput, type: .audio) }
            }
            await capture.stopForPhase1Probe()
            _ = referenceCollector.reportAndRelease(requestedDurationSeconds: Self.captureDurationSeconds)
            _ = microphoneCollector.reportAndRelease(requestedDurationSeconds: Self.captureDurationSeconds)
            return Self.failure("Trial A capture failed")
        }
        referenceCollector.markCaptureClosed()
        microphoneCollector.markCaptureClosed()
        let voiceProcessingReadback = await capture.voiceProcessingProbeReadback()
        if let stream {
            do { try await Self.withTimeout(seconds: Self.operationTimeoutSeconds) { try await stream.stopCapture() } }
            catch { stopErrorCount += 1 }
            if let streamOutput {
                do { try await stream.removeStreamOutput(streamOutput, type: .audio) }
                catch { stopErrorCount += 1 }
            }
        }
        // Observe the route and volume while the VPIO generation is still live; teardown may
        // legitimately release the transient I/O unit and would hide a capture-time route change.
        let postCaptureRouteConfirmed = Self.routeIsStillSafe(
            microphoneUID: microphoneDevice.coreAudioUID, outputDeviceID: outputDevice.id)
        let postCaptureOutputVolume = Self.readOutputVolume(
            AudioDevice.getDefaultOutputDevice()?.id ?? kAudioObjectUnknown).map(Double.init)
        await capture.stopForPhase1Probe()
        let reference = referenceCollector.reportAndRelease(requestedDurationSeconds: Self.captureDurationSeconds)
        let microphoneReport = microphoneCollector.reportAndRelease(requestedDurationSeconds: Self.captureDurationSeconds)
        let volumeUnchanged = postCaptureOutputVolume.map {
            abs($0 - Double(volume)) <= 0.0001
        } == true
        let measuredCombinedPeak = postCaptureOutputVolume.map {
            (reference.peak ?? 0) * $0
        }
        let targetProcessStable = NSRunningApplication(processIdentifier: application.processID)?.isTerminated == false
        let voiceProcessingReadbackValid = Self.voiceProcessingReadbackIsValid(
            voiceProcessingReadback, inputDeviceID: inputDevice.id, outputDeviceID: outputDevice.id)
        let captureValid = reference.timingValid && microphoneReport.timingValid
            && postCaptureRouteConfirmed && volumeUnchanged
            && (measuredCombinedPeak ?? .infinity) <= 0.15
            && (reference.peak ?? 0) >= 0.001
            && streamDelegate.errorCount == 0
            && stopErrorCount == 0
            && targetProcessStable
            && voiceProcessingReadbackValid
        let clock = MeetingExternalReferenceTrialAClockReport(
            sharedClockEstablished: false, acousticDelaySeconds: nil,
            relationship: "independent PTS origins; no defensible clock mapping",
            reason: "per-buffer PTS cannot establish an acoustic capture/reference mapping")
        let report = MeetingExternalReferenceTrialAReport(
            schemaVersion: MeetingExternalReferenceTrialAReport.currentSchemaVersion,
            targetBundleID: targetBundleID, targetProcessID: application.processID,
            targetProcessStable: targetProcessStable,
            selectionConfirmed: true,
            microphoneDeviceID: inputDevice.id,
            defaultInputDeviceID: AudioDevice.getDefaultInputDevice()?.id,
            outputDeviceID: outputDevice.id, defaultOutputDeviceID: AudioDevice.getDefaultOutputDevice()?.id,
            builtInRouteConfirmed: true,
            postCaptureRouteConfirmed: postCaptureRouteConfirmed,
            outputVolume: Double(volume), postCaptureOutputVolume: postCaptureOutputVolume,
            outputVolumeReadable: true, outputVolumeUnchanged: volumeUnchanged,
            combinedPeakBound: combinedPeakBound,
            measuredCombinedPeak: measuredCombinedPeak,
            referenceExcitationConfirmed: (reference.peak ?? 0) >= 0.001,
            streamErrorCount: streamDelegate.errorCount,
            stopErrorCount: stopErrorCount,
            reference: reference, microphone: microphoneReport,
            clock: clock, voiceProcessingReadback: voiceProcessingReadback,
            appOwnedPlayback: false, rawPCMRetained: false,
            transcriptRetained: false, persisted: false,
            captureValid: captureValid, acousticMeasurementValid: false,
            reasons: ["diagnostic-only", "no app-owned playback", "independent clocks; acoustic delay unknown"]
                + ((reference.peak ?? 0) >= 0.001 ? [] : ["reference below excitation floor"])
                + (postCaptureRouteConfirmed ? [] : ["capture-time route changed or became unreadable"])
                + (volumeUnchanged ? [] : ["output volume changed during capture"])
                + ((measuredCombinedPeak ?? .infinity) <= 0.15 ? [] : ["measured combined peak exceeded 0.15"])
                + (reference.timingValid && microphoneReport.timingValid ? [] : ["timing invalid or bounded collector dropped audio"])
                + (streamDelegate.errorCount == 0 ? [] : ["ScreenCaptureKit stream stopped with error"])
                + (stopErrorCount == 0 ? [] : ["stream stop or output cleanup failed"])
                + (targetProcessStable ? [] : ["target process became unstable"])
                + (voiceProcessingReadbackValid ? [] : ["VPIO engine/voice-processing device readback was not verified"]))
        do {
            let data = try JSONEncoder.sorted.encode(report)
            return Self.success(String(decoding: data, as: UTF8.self))
        } catch { return Self.failure("numeric Trial A report serialization failed") }
    }

    private static func readOutputVolume(_ deviceID: AudioObjectID) -> Float32? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var value: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
               value.isFinite, (0...1).contains(value) { return value }
        }
        return nil
    }

    private static func routeIsStillSafe(microphoneUID: String?, outputDeviceID: AudioObjectID) -> Bool {
        guard let microphoneUID,
              let input = AudioDevice.listInputDevices().first(where: { $0.uid == microphoneUID }),
              input.isAlive, input.isBuiltIn,
              AudioDevice.getDefaultInputDevice()?.uid == microphoneUID,
              let output = AudioDevice.getDefaultOutputDevice(), output.isAlive,
              output.id == outputDeviceID,
              MeetingCapturePathDecider.outputRouteDeclineReason(
                  MeetingCaptureEngine.currentOutputRouteSnapshot()) == nil,
              let volume = Self.readOutputVolume(output.id), volume > 0, volume <= 0.6 else {
            return false
        }
        return true
    }

    private static func voiceProcessingReadbackIsValid(
        _ snapshot: MeetingVoiceProcessingProbeSnapshot?,
        inputDeviceID: AudioObjectID,
        outputDeviceID: AudioObjectID
    ) -> Bool {
        guard let snapshot,
              snapshot.engineRunning,
              snapshot.nodeVoiceProcessingEnabled,
              !snapshot.nodeVoiceProcessingBypassed,
              snapshot.nodeVoiceProcessingAGCEnabled,
              snapshot.inputCurrentDevice.status == noErr,
              snapshot.outputCurrentDevice.status == noErr,
              snapshot.inputCurrentDevice.value == inputDeviceID,
              snapshot.outputCurrentDevice.value == outputDeviceID,
              snapshot.bypassVoiceProcessing.status == noErr,
              snapshot.bypassVoiceProcessing.value == 0,
              snapshot.voiceProcessingAGCEnabled.status == noErr,
              snapshot.voiceProcessingAGCEnabled.value == 1 else {
            return false
        }
        return true
    }

    private static func success(_ reportJSON: String) -> Outcome {
        guard let data = reportJSON.data(using: .utf8),
              let report = try? JSONSerialization.jsonObject(with: data),
              let line = Self.jsonLine(["exitStatus": 0, "report": report, "status": "success"]) else {
            return Self.failure("numeric Trial A report serialization failed")
        }
        return Outcome(exitStatus: 0, line: line)
    }
    private static func failure(_ reason: String) -> Outcome {
        let line = Self.jsonLine(["exitStatus": 1, "reason": reason, "status": "failure"])
            ?? "{\"exitStatus\":1,\"status\":\"failure\"}"
        return Outcome(exitStatus: 1, line: line)
    }
    private static func jsonLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
    private static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw RunError.timeout }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private final class TrialAStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let collector: MeetingExternalReferenceTrialACollector
    init(collector: MeetingExternalReferenceTrialACollector) { self.collector = collector }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        self.collector.ingest(sampleBuffer)
    }
}

private final class TrialAStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stoppedWithErrorCount = 0
    var errorCount: Int { lock.lock(); defer { lock.unlock() }; return stoppedWithErrorCount }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); stoppedWithErrorCount += 1; lock.unlock()
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}

#endif
