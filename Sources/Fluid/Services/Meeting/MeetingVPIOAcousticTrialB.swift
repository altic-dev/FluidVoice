#if DEBUG

    import AVFoundation
    import CoreMedia
    import Darwin
    import Foundation
    import os

    // MARK: - Gate

    /// Trial B renders audio and mutates VPIO controls. It exists only in DEBUG and only when the
    /// explicit dual hardware-probe gate is present: `FLUIDVOICE_VPIO_ACOUSTIC=1` and a finite
    /// `FLUIDVOICE_MIC_PHASE1` duration in the bounded probe interval. No production path can
    /// reach it.
    nonisolated enum MeetingVPIOAcousticGate {
        static let maximumProbeMinutes = 0.25
        static let maximumSystemVolume = 0.6
        static let maximumCombinedPeak = 0.15

        static var isEnabled: Bool {
            self.isEnabled(environment: ProcessInfo.processInfo.environment)
        }

        static func isEnabled(environment: [String: String]) -> Bool {
            guard environment["FLUIDVOICE_VPIO_ACOUSTIC"] == "1",
                  let minutes = environment["FLUIDVOICE_MIC_PHASE1"].flatMap(Double.init),
                  minutes > 0,
                  minutes <= Self.maximumProbeMinutes,
                  minutes.isFinite
            else {
                return false
            }
            return true
        }
    }

    /// mach ticks to seconds, matching `MeetingMicrophonePTSClock`'s conversion so render times and
    /// capture presentation stamps live on one grid.
    nonisolated enum MeetingVPIOAcousticHostClock {
        private static let timebase: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return info
        }()

        static func seconds(_ hostTime: UInt64) -> Double {
            guard self.timebase.denom > 0 else { return Double(hostTime) / 1_000_000_000 }
            return Double(hostTime) * Double(self.timebase.numer) / Double(self.timebase.denom) / 1_000_000_000
        }
    }

    // MARK: - Report records

    /// Evidence that the stimulus actually reached the engine's output path, independent of the
    /// microphone: without it a silent capture cannot be told apart from a silent render.
    nonisolated struct MeetingVPIOAcousticRenderConfirmation: Codable, Equatable, Sendable {
        var scheduledFrameCount: Int
        var sampleRate: Double
        var volume: Double
        var mixerSampleRate: Double
        var mixerChannelCount: Int
        var tapFrameCount: Int
        var tapRMS: Double
        var tapPeak: Double
        var tapInvalidHostTimeCount: Int
        /// Host-time seconds of the first mixer sample above the activity floor. This is after the
        /// stimulus's leading silence; Trial B converts it to stimulus sample-zero before windowing.
        var renderStartHostSeconds: Double?
        /// Independent estimate derived from the player's own sample clock; a large disagreement
        /// with `renderStartHostSeconds` invalidates the delay, it does not average with it.
        var playerDerivedStartHostSeconds: Double?
        var playerRenderedFrameCount: Int?
        var renderStartResolved: Bool
        var outputConnectionCount: Int
        var outputDeviceID: UInt32?
        var defaultOutputDeviceID: UInt32?
        var outputRouteConfirmed: Bool
        var systemVolume: Double?
        var outputVolumeReadable: Bool
        var combinedPeak: Double?
        var reasons: [MeetingVPIOAcousticReason]
    }

    /// Read-only safety preflight for a local render. It records only route/volume numbers and
    /// typed refusal reasons; it never changes the system volume or audio-device controls.
    nonisolated struct MeetingVPIOAcousticOutputPreflight: Codable, Equatable, Sendable {
        var outputConnectionCount: Int
        var outputDeviceID: UInt32?
        var defaultOutputDeviceID: UInt32?
        var outputRouteConfirmed: Bool
        var systemVolume: Double?
        var outputVolumeReadable: Bool
        var combinedPeak: Double?
        var reasons: [MeetingVPIOAcousticReason]

        var isSafe: Bool { self.reasons.isEmpty }
    }

    nonisolated struct MeetingVPIOAcousticControlState: Codable, Equatable, Sendable {
        var requestedBypass: Bool
        var appliedBypass: Bool?
        var requestedAGCEnabled: Bool
        var appliedAGCEnabled: Bool?
        var readbackBypass: Bool?
        var readbackAGCEnabled: Bool?
        var readbackBypassRawValue: UInt32?
        var readbackAGCRawValue: UInt32?
        var readbackBypassStatus: OSStatus?
        var readbackAGCStatus: OSStatus?
        var applied: Bool
    }

    nonisolated struct MeetingVPIOAcousticCaptureWindow: Codable, Equatable, Sendable {
        var startHostSeconds: Double
        var frameCount: Int
        var writtenFrameCount: Int
        var coverage: Double
        var contributingSegmentCount: Int
        var overlapFrameCount: Int
        var synthesizedFrameCount: Int
        var resyncedSegmentCount: Int
    }

    nonisolated struct MeetingVPIOAcousticRun: Codable, Equatable, Sendable {
        var variant: String
        var control: MeetingVPIOAcousticControlState
        var render: MeetingVPIOAcousticRenderConfirmation?
        var captureWindow: MeetingVPIOAcousticCaptureWindow?
        var measurement: MeetingVPIOAcousticMeasurement?
        var valid: Bool
        var reasons: [MeetingVPIOAcousticReason]
    }

    nonisolated struct MeetingVPIOAcousticTrialBReport: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        /// Carried in the sidecar so a reader cannot lift a number out of it as an AEC result.
        static let interpretationCaveats = [
            "Trial B renders known local PCM through this process's own VPIO output path; it does not route another application's audio and says nothing about whether Apple's echo reference receives other-process playback.",
            "attenuationDB compares an electrical reference against an acoustic capture and is uncalibrated. Only differences between variants measured back-to-back on one unchanged rig are readable, and even those are confounded by speaker level, room, and AGC.",
            "A single run establishes neither echo cancellation nor its absence. Treat every number as configuration and coupling evidence pending the paired ScreenCaptureKit topology comparison.",
        ]

        var schemaVersion: Int
        var stimulus: MeetingVPIOAcousticStimulusDescriptor
        var renderVolume: Double
        var preRollSeconds: Double
        var postRollSeconds: Double
        var settleSeconds: Double
        var runs: [MeetingVPIOAcousticRun]
        var caveats: [String]
    }

    // MARK: - Capture collector

    /// Holds the probe's already-emitted mono capture in memory for the duration of the trial so
    /// the metrics can be aligned to render time. Nothing here is written to disk, and only numbers
    /// leave it.
    final nonisolated class MeetingVPIOAcousticCaptureCollector: @unchecked Sendable {
        private nonisolated struct Segment: Sendable {
            var startSeconds: Double
            var samples: [Float]
            var synthesized: Bool
            var resynced: Bool
        }

        private nonisolated struct State: Sendable {
            var segments: [Segment] = []
            var frameCount = 0
        }

        /// 20 s at 48 kHz: enough for every variant window, bounded so a long probe cannot grow
        /// without limit.
        private nonisolated static let maximumRetainedFrames = 960_000

        private nonisolated let lock = OSAllocatedUnfairLock(initialState: State())

        nonisolated func ingest(_ sampleBuffer: CMSampleBuffer, synthesized: Bool = false, resynced: Bool = false) {
            guard let sample = MeetingLiveSampleCopy.copy(sampleBuffer),
                  let channel = sample.buffer.floatChannelData?[0]
            else { return }
            let frameCount = Int(sample.buffer.frameLength)
            guard frameCount > 0, sample.pts.isNumeric else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
            let segment = Segment(
                startSeconds: sample.pts.seconds,
                samples: samples,
                synthesized: synthesized,
                resynced: resynced
            )

            self.lock.withLock { state in
                state.segments.append(segment)
                state.frameCount += frameCount
                while state.frameCount > Self.maximumRetainedFrames, !state.segments.isEmpty {
                    state.frameCount -= state.segments.removeFirst().samples.count
                }
            }
        }

        nonisolated func reset() {
            self.lock.withLock { $0 = State() }
        }

        /// Places every retained segment on a host-time grid starting at `startHostSeconds`. Gaps
        /// stay zero and are reported through `coverage`; a partially covered window is never
        /// silently treated as a complete one.
        nonisolated func window(
            startHostSeconds: Double,
            frameCount: Int,
            sampleRate: Double
        ) -> (samples: [Float], window: MeetingVPIOAcousticCaptureWindow) {
            let count = max(0, frameCount)
            var samples = [Float](repeating: 0, count: count)
            var filled = [Bool](repeating: false, count: count)
            var overlap = 0
            var contributing = 0
            var synthesizedFrameCount = 0
            var resyncedSegmentCount = 0
            let segments = self.lock.withLock { $0.segments }

            for segment in segments {
                let offset = Int(((segment.startSeconds - startHostSeconds) * sampleRate).rounded())
                let start = max(0, offset)
                let end = min(count, offset + segment.samples.count)
                guard start < end else { continue }
                contributing += 1
                if segment.resynced { resyncedSegmentCount += 1 }
                for index in start..<end {
                    if filled[index] { overlap += 1 }
                    let wasFilled = filled[index]
                    filled[index] = true
                    if segment.synthesized, !wasFilled { synthesizedFrameCount += 1 }
                    samples[index] = segment.samples[index - offset]
                }
            }
            let written = filled.filter { $0 }.count

            return (
                samples,
                MeetingVPIOAcousticCaptureWindow(
                    startHostSeconds: startHostSeconds,
                    frameCount: count,
                    writtenFrameCount: written,
                    coverage: count > 0 ? Double(written) / Double(count) : 0,
                    contributingSegmentCount: contributing,
                    overlapFrameCount: overlap,
                    synthesizedFrameCount: synthesizedFrameCount,
                    resyncedSegmentCount: resyncedSegmentCount
                )
            )
        }
    }

    // MARK: - Runner

    /// Controlled acoustic Trial B: render a deterministic stimulus through the running VPIO
    /// engine's own output and measure what the VPIO input returns, once per control variant.
    nonisolated enum MeetingVPIOAcousticTrialB {
        struct Variant: Sendable {
            var name: String
            var bypassVoiceProcessing: Bool
            var agcEnabled: Bool
        }

        /// Baseline first, then one changed control at a time. Only properties with public setters
        /// are varied; `setVoiceProcessingEnabled` is never touched here (see the teardown note in
        /// `MeetingMicrophoneCapture.stop`).
        static let variants: [Variant] = [
            Variant(name: "vpioActive", bypassVoiceProcessing: false, agcEnabled: true),
            Variant(name: "vpioActiveNoAGC", bypassVoiceProcessing: false, agcEnabled: false),
            Variant(name: "vpioBypassed", bypassVoiceProcessing: true, agcEnabled: true),
        ]

        static let renderVolume: Float = 0.5
        static let settleSeconds = 0.35
        static let preRollSeconds = 0.30
        static let postRollSeconds = 0.60
        static let interVariantSeconds = 0.50
        /// The tap emits 100 ms aggregate buffers. Let a reset establish a complete pre-roll
        /// window, with one buffer-period margin for callback/flush scheduling, before playback.
        static let collectorWarmupSeconds = Self.preRollSeconds + 0.15

        private static func orderedReasons(_ reasons: [MeetingVPIOAcousticReason]) -> [MeetingVPIOAcousticReason] {
            var seen = Set<MeetingVPIOAcousticReason>()
            return reasons.filter { seen.insert($0).inserted }.sorted { $0.rawValue < $1.rawValue }
        }

        /// The mixer tap reports first activity, while the reference array begins at stimulus
        /// sample zero. Keep the conversion explicit so leading silence cannot shift the window
        /// and hide its trailing capture in an otherwise complete run.
        static func stimulusSampleZeroHostSeconds(
            renderActivityStartHostSeconds: Double,
            leadingSilenceFrameCount: Int,
            sampleRate: Double
        ) -> Double? {
            guard renderActivityStartHostSeconds.isFinite,
                  leadingSilenceFrameCount >= 0,
                  sampleRate.isFinite,
                  sampleRate > 0
            else { return nil }
            return renderActivityStartHostSeconds - Double(leadingSilenceFrameCount) / sampleRate
        }

        static func isRequested() -> Bool { MeetingVPIOAcousticGate.isEnabled }

        static func run(
            capture: MeetingMicrophoneCapture,
            collector: MeetingVPIOAcousticCaptureCollector,
            sampleRate: Double = 48_000
        ) async -> MeetingVPIOAcousticTrialBReport? {
            guard MeetingVPIOAcousticGate.isEnabled else { return nil }
            guard let stimulus = MeetingVPIOAcousticStimulus.make(sampleRate: sampleRate) else { return nil }

            var runs: [MeetingVPIOAcousticRun] = []
            guard stimulus.descriptor.withinSafetyBounds else {
                // Refuse to render rather than emit an unbounded level.
                return MeetingVPIOAcousticTrialBReport(
                    schemaVersion: MeetingVPIOAcousticTrialBReport.currentSchemaVersion,
                    stimulus: stimulus.descriptor,
                    renderVolume: Double(Self.renderVolume),
                    preRollSeconds: Self.preRollSeconds,
                    postRollSeconds: Self.postRollSeconds,
                    settleSeconds: Self.settleSeconds,
                    runs: [],
                    caveats: MeetingVPIOAcousticTrialBReport.interpretationCaveats
                        + ["Stimulus fell outside its RMS/peak safety bounds; nothing was rendered."]
                )
            }

            let preRunSnapshot = await capture.voiceProcessingProbeReadback()
            guard let preRunControl = preRunSnapshot.flatMap(Self.validatedControlState) else {
                return MeetingVPIOAcousticTrialBReport(
                    schemaVersion: MeetingVPIOAcousticTrialBReport.currentSchemaVersion,
                    stimulus: stimulus.descriptor,
                    renderVolume: Double(Self.renderVolume),
                    preRollSeconds: Self.preRollSeconds,
                    postRollSeconds: Self.postRollSeconds,
                    settleSeconds: Self.settleSeconds,
                    runs: [],
                    caveats: MeetingVPIOAcousticTrialBReport.interpretationCaveats
                        + ["Pre-run VPIO control getter/raw read-backs were unavailable or inconsistent; no variant was rendered."]
                )
            }
            for variant in Self.variants {
                // Cancellation is cooperative: stop starting new variants, then restore the
                // production controls below before this task returns.
                guard !Task.isCancelled else { break }
                runs.append(
                    await Self.runVariant(
                        variant,
                        capture: capture,
                        collector: collector,
                        stimulus: stimulus,
                        sampleRate: sampleRate
                    )
                )
                try? await Task.sleep(nanoseconds: UInt64(Self.interVariantSeconds * 1_000_000_000))
            }

            // Restore the actual pre-run controls. Never assume Apple's defaults and never touch
            // the VPIO enable bit here.
            _ = await capture.setVoiceProcessingBypassedForProbe(preRunControl.bypassed)
            _ = await capture.setVoiceProcessingAGCEnabledForProbe(preRunControl.agcEnabled)

            return MeetingVPIOAcousticTrialBReport(
                schemaVersion: MeetingVPIOAcousticTrialBReport.currentSchemaVersion,
                stimulus: stimulus.descriptor,
                renderVolume: Double(Self.renderVolume),
                preRollSeconds: Self.preRollSeconds,
                postRollSeconds: Self.postRollSeconds,
                settleSeconds: Self.settleSeconds,
                runs: runs,
                caveats: MeetingVPIOAcousticTrialBReport.interpretationCaveats
            )
        }

        private static func runVariant(
            _ variant: Variant,
            capture: MeetingMicrophoneCapture,
            collector: MeetingVPIOAcousticCaptureCollector,
            stimulus: MeetingVPIOAcousticStimulus.Generated,
            sampleRate: Double
        ) async -> MeetingVPIOAcousticRun {
            let appliedBypass = await capture.setVoiceProcessingBypassedForProbe(variant.bypassVoiceProcessing)
            let appliedAGC = await capture.setVoiceProcessingAGCEnabledForProbe(variant.agcEnabled)
            try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))

            let snapshot = await capture.voiceProcessingProbeReadback()
            var control = MeetingVPIOAcousticControlState(
                requestedBypass: variant.bypassVoiceProcessing,
                appliedBypass: appliedBypass,
                requestedAGCEnabled: variant.agcEnabled,
                appliedAGCEnabled: appliedAGC,
                readbackBypass: snapshot?.nodeVoiceProcessingBypassed,
                readbackAGCEnabled: snapshot?.nodeVoiceProcessingAGCEnabled,
                readbackBypassRawValue: snapshot?.bypassVoiceProcessing.value,
                readbackAGCRawValue: snapshot?.voiceProcessingAGCEnabled.value,
                readbackBypassStatus: snapshot?.bypassVoiceProcessing.status,
                readbackAGCStatus: snapshot?.voiceProcessingAGCEnabled.status,
                applied: false
            )
            control.applied = snapshot?.bypassVoiceProcessing.succeeded == true
                && snapshot?.voiceProcessingAGCEnabled.succeeded == true
                && snapshot?.bypassVoiceProcessing.value == UInt32(variant.bypassVoiceProcessing ? 1 : 0)
                && snapshot?.voiceProcessingAGCEnabled.value == UInt32(variant.agcEnabled ? 1 : 0)
                && control.readbackBypass == variant.bypassVoiceProcessing
                && control.readbackAGCEnabled == variant.agcEnabled

            var reasons: [MeetingVPIOAcousticReason] = []
            if !control.applied { reasons.append(.controlNotApplied) }
            if Task.isCancelled {
                reasons.append(.probeCancelled)
                return MeetingVPIOAcousticRun(
                    variant: variant.name,
                    control: control,
                    render: nil,
                    captureWindow: nil,
                    measurement: nil,
                    valid: false,
                    reasons: Self.orderedReasons(reasons)
                )
            }

            collector.reset()
            try? await Task.sleep(nanoseconds: UInt64(Self.collectorWarmupSeconds * 1_000_000_000))
            guard !Task.isCancelled else {
                reasons.append(.probeCancelled)
                return MeetingVPIOAcousticRun(
                    variant: variant.name,
                    control: control,
                    render: nil,
                    captureWindow: nil,
                    measurement: nil,
                    valid: false,
                    reasons: Self.orderedReasons(reasons)
                )
            }
            let render: MeetingVPIOAcousticRenderConfirmation
            do {
                render = try await capture.playVoiceProcessingProbePCM(
                    stimulus.samples,
                    sampleRate: sampleRate,
                    volume: Self.renderVolume
                )
            } catch {
                switch error {
                case is CancellationError: reasons.append(.probeCancelled)
                case MeetingVoiceProcessingProbeError.captureNotRunning: reasons.append(.captureNotRunning)
                case MeetingVoiceProcessingProbeError.invalidPlaybackFormat: reasons.append(.insufficientFrames)
                case MeetingVoiceProcessingProbeError.playbackTimedOut: reasons.append(.playbackTimedOut)
                default: reasons.append(.probeDisabled)
                }
                return MeetingVPIOAcousticRun(
                    variant: variant.name,
                    control: control,
                    render: nil,
                    captureWindow: nil,
                    measurement: nil,
                    valid: false,
                    reasons: Self.orderedReasons(reasons)
                )
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.postRollSeconds * 1_000_000_000))

            reasons.append(contentsOf: render.reasons)
            guard let renderActivityStart = render.renderStartHostSeconds,
                  let renderStart = Self.stimulusSampleZeroHostSeconds(
                      renderActivityStartHostSeconds: renderActivityStart,
                      leadingSilenceFrameCount: stimulus.descriptor.leadingSilenceFrameCount,
                      sampleRate: sampleRate
                  )
            else {
                reasons.append(.renderTimingInvalid)
                return MeetingVPIOAcousticRun(
                    variant: variant.name,
                    control: control,
                    render: render,
                    captureWindow: nil,
                    measurement: nil,
                    valid: false,
                    reasons: Self.orderedReasons(reasons)
                )
            }

            let preRollFrames = Int((Self.preRollSeconds * sampleRate).rounded())
            let tailFrames = Int((Self.postRollSeconds * sampleRate).rounded())
            let windowFrames = preRollFrames + stimulus.samples.count + tailFrames
            let captured = collector.window(
                startHostSeconds: renderStart - Self.preRollSeconds,
                frameCount: windowFrames,
                sampleRate: sampleRate
            )
            // A Trial B delay is only meaningful on a complete, non-overlapping shared-clock
            // window. Never turn missing or doubly-written capture into zeroes and then score it.
            if captured.window.coverage < 1.0 {
                reasons.append(.captureGap)
                reasons.append(.captureWindowIncomplete)
            }
            if captured.window.overlapFrameCount > 0 {
                reasons.append(.captureOverlap)
            }
            if captured.window.synthesizedFrameCount > 0 {
                reasons.append(.captureTimingSynthesized)
                if captured.window.resyncedSegmentCount == 0 {
                    reasons.append(.captureTimingResyncRequired)
                }
            }
            if captured.window.coverage < 1.0 || captured.window.overlapFrameCount > 0
                || captured.window.synthesizedFrameCount > 0
            {
                return MeetingVPIOAcousticRun(
                    variant: variant.name,
                    control: control,
                    render: render,
                    captureWindow: captured.window,
                    measurement: nil,
                    valid: false,
                    reasons: Self.orderedReasons(reasons)
                )
            }

            // The reference is the stimulus as rendered — scaled by the player's gain — placed at
            // the same pre-roll offset as the capture window.
            var reference = [Float](repeating: 0, count: windowFrames)
            let volume = Float(render.volume)
            for index in 0..<stimulus.samples.count where preRollFrames + index < windowFrames {
                reference[preRollFrames + index] = stimulus.samples[index] * volume
            }

            let measurement = MeetingVPIOAcousticMetrics.measure(
                reference: reference,
                captured: captured.samples,
                sampleRate: sampleRate,
                silencePrefixFrames: preRollFrames + stimulus.descriptor.leadingSilenceFrameCount
            )

            return MeetingVPIOAcousticRun(
                variant: variant.name,
                control: control,
                render: render,
                captureWindow: captured.window,
                measurement: measurement,
                valid: measurement.valid && reasons.isEmpty,
                reasons: Self.orderedReasons(reasons + measurement.reasons)
            )
        }

        private static func validatedControlState(
            _ snapshot: MeetingVoiceProcessingProbeSnapshot
        ) -> (bypassed: Bool, agcEnabled: Bool)? {
            guard snapshot.bypassVoiceProcessing.succeeded,
                  snapshot.voiceProcessingAGCEnabled.succeeded,
                  let rawBypass = snapshot.bypassVoiceProcessing.value,
                  let rawAGC = snapshot.voiceProcessingAGCEnabled.value,
                  rawBypass <= 1,
                  rawAGC <= 1,
                  snapshot.nodeVoiceProcessingBypassed == (rawBypass == 1),
                  snapshot.nodeVoiceProcessingAGCEnabled == (rawAGC == 1)
            else { return nil }
            return (rawBypass == 1, rawAGC == 1)
        }
    }

#endif
