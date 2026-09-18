#if DEBUG

import AVFoundation
import CoreAudio
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Pure, metadata-only handshake logic for the controlled stimulus window.  The runtime polls
/// ScreenCaptureKit snapshots, while these decisions remain deterministic and independently
/// testable without opening Chrome or recording audio.
nonisolated enum MeetingStage05StimulusHandshake {
    static let readyTitle = "FluidVoice C2 Diagnostic Stimulus — READY"
    static let maximumPlayingSeconds = 24
    static let minimumRemainingSeconds = 22

    enum Decision: Equatable, Sendable {
        case waiting
        case success(MeetingExternalReferenceTrialAWindowCandidate)
        case failure(Failure)
    }

    enum Failure: Error, Equatable, Sendable {
        case ambiguous
        case ownerChanged
        case processChanged
        case windowChanged
        case malformedState
        case remainingInsufficient
        case timeout
    }

    static func selectReadyWindow(
        from windows: [MeetingExternalReferenceTrialAWindowCandidate],
        targetBundleIdentifier: String
    ) -> MeetingExternalReferenceTrialAWindowCandidate? {
        let matches = windows.filter {
            $0.windowID != 0
                && $0.owningBundleIdentifier == targetBundleIdentifier
                && $0.owningProcessID > 0
                && $0.title == Self.readyTitle
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func decision(
        for ready: MeetingExternalReferenceTrialAWindowCandidate,
        current windows: [MeetingExternalReferenceTrialAWindowCandidate],
        targetBundleIdentifier: String,
        now: Double,
        deadline: Double
    ) -> Decision {
        guard now.isFinite, deadline.isFinite, deadline >= now else { return .failure(.timeout) }
        let controlledPlaying = windows.filter {
            $0.windowID != 0
                && $0.owningBundleIdentifier == targetBundleIdentifier
                && $0.owningProcessID > 0
                && Self.playingRemainingSeconds($0.title) != nil
        }
        guard controlledPlaying.count <= 1 else { return .failure(.ambiguous) }
        guard let current = windows.first(where: { $0.windowID == ready.windowID }) else {
            return .failure(.windowChanged)
        }
        guard current.owningBundleIdentifier == ready.owningBundleIdentifier else {
            return .failure(.ownerChanged)
        }
        guard current.owningProcessID == ready.owningProcessID else {
            return .failure(.processChanged)
        }
        guard current.title == Self.readyTitle || Self.playingRemainingSeconds(current.title) != nil else {
            return .failure(.malformedState)
        }
        if let playing = controlledPlaying.first {
            guard playing.windowID == ready.windowID else { return .failure(.ambiguous) }
            guard let remaining = Self.playingRemainingSeconds(playing.title),
                  remaining >= Double(Self.minimumRemainingSeconds) else {
                return .failure(.remainingInsufficient)
            }
            return .success(playing)
        }
        return now >= deadline ? .failure(.timeout) : .waiting
    }

    static func playingRemainingSeconds(_ title: String?) -> Double? {
        let prefix = "FluidVoice C2 Diagnostic Stimulus — PLAYING — "
        guard let title, title.hasPrefix(prefix), title.hasSuffix("s") else { return nil }
        let digits = title.dropFirst(prefix.count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let value = Int(digits), (0...Self.maximumPlayingSeconds).contains(value) else { return nil }
        return Double(value)
    }
}

/// Privacy-safe result of feeding the completed real callback set through the DEBUG-only
/// synchronizer and identity/mock AEC seam. Every stored property is numeric or Boolean;
/// callback times, audio, device/process identity, paths, titles, and arbitrary labels are
/// deliberately excluded.
nonisolated struct MeetingStage05LiveAdapterSummary: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumCount = 2_000_000

    let schema: Int
    let renderAcceptedCallbackCount: Int
    let renderRejectedCallbackCount: Int
    let renderGapCount: Int
    let renderOverlapCount: Int
    let renderBackwardCount: Int
    let renderDiscontinuityCount: Int
    let renderFormatChangeCount: Int
    let captureAcceptedCallbackCount: Int
    let captureRejectedCallbackCount: Int
    let captureGapCount: Int
    let captureOverlapCount: Int
    let captureBackwardCount: Int
    let captureDiscontinuityCount: Int
    let captureFormatChangeCount: Int
    let synchronizerFailedOpen: Bool
    let synchronizerInputFrameCount: Int
    let synchronizerOutputFrameCount: Int
    let synchronizerEpochCount: Int
    let synchronizerDroppedFrameCount: Int
    let synchronizerDuplicateOrLateFrameCount: Int
    let synchronizerNonFiniteSampleCount: Int
    let synchronizerSynthesizedMicrophoneFrameCount: Int
    let synchronizerBoundedResourceFailure: Bool
    let referenceClockDriftPresent: Bool
    let referenceClockDriftPPM: Double
    let renderSampleCount: Int
    let renderValidSampleCount: Int
    let captureSampleCount: Int
    let captureValidSampleCount: Int
    let mockAuthorized: Bool
    let mockProcessedFrameCount: Int
    let mockFrozenFrameCount: Int
    let mockBoundaryCount: Int
    let renderBeforeCaptureValid: Bool
    let eligibleForAECTrial: Bool

    static func make(
        drain: MeetingStage05AdapterDrain,
        synchronization: MeetingSynchronizationResult,
        seam: MeetingStage05MockAECSeamResult
    ) -> Self {
        let renderSamples = boundedSum(synchronization.frames.map { $0.renderSamples.count })
        let renderValid = boundedSum(synchronization.frames.map {
            $0.renderValidMask.lazy.filter { $0 }.count
        })
        let captureSamples = boundedSum(synchronization.frames.map { $0.captureSamples.count })
        let captureValid = boundedSum(synchronization.frames.map {
            $0.captureValidMask.lazy.filter { $0 }.count
        })
        let drift = synchronization.diagnostics.referenceClockDriftPPM.flatMap {
            $0.isFinite ? $0 : nil
        }
        let orderingValid = eventsAreRenderBeforeCapture(seam)
        let render = drain.renderDiagnostics
        let capture = drain.microphoneDiagnostics
        let cleanCallbacks = [
            render.rejectedCallbackCount, render.gapCount, render.overlapCount,
            render.backwardCount, render.discontinuityCount, render.formatChangeCount,
            capture.rejectedCallbackCount, capture.gapCount, capture.overlapCount,
            capture.backwardCount, capture.discontinuityCount, capture.formatChangeCount,
        ].allSatisfy { $0 == 0 }
        let diagnostics = synchronization.diagnostics
        let eligible = cleanCallbacks
            && !synchronization.failedOpen
            && !diagnostics.boundedResourceFailure
            && diagnostics.droppedFrameCount == 0
            && diagnostics.duplicateOrLateFrameCount == 0
            && diagnostics.nonFiniteSampleCount == 0
            && diagnostics.synthesizedMicrophoneFrameCount == 0
            && diagnostics.epochCount == 1
            && !synchronization.frames.isEmpty
            && renderSamples == renderValid
            && captureSamples == captureValid
            && seam.authorized
            && seam.processedFrameCount == synchronization.frames.count
            && seam.frozenFrameCount == 0
            && seam.boundaryCount == 0
            && orderingValid
        return Self(
            schema: Self.schemaVersion,
            renderAcceptedCallbackCount: render.acceptedCallbackCount,
            renderRejectedCallbackCount: render.rejectedCallbackCount,
            renderGapCount: render.gapCount,
            renderOverlapCount: render.overlapCount,
            renderBackwardCount: render.backwardCount,
            renderDiscontinuityCount: render.discontinuityCount,
            renderFormatChangeCount: render.formatChangeCount,
            captureAcceptedCallbackCount: capture.acceptedCallbackCount,
            captureRejectedCallbackCount: capture.rejectedCallbackCount,
            captureGapCount: capture.gapCount,
            captureOverlapCount: capture.overlapCount,
            captureBackwardCount: capture.backwardCount,
            captureDiscontinuityCount: capture.discontinuityCount,
            captureFormatChangeCount: capture.formatChangeCount,
            synchronizerFailedOpen: synchronization.failedOpen,
            synchronizerInputFrameCount: diagnostics.inputFrameCount,
            synchronizerOutputFrameCount: synchronization.frames.count,
            synchronizerEpochCount: diagnostics.epochCount,
            synchronizerDroppedFrameCount: diagnostics.droppedFrameCount,
            synchronizerDuplicateOrLateFrameCount: diagnostics.duplicateOrLateFrameCount,
            synchronizerNonFiniteSampleCount: diagnostics.nonFiniteSampleCount,
            synchronizerSynthesizedMicrophoneFrameCount: diagnostics.synthesizedMicrophoneFrameCount,
            synchronizerBoundedResourceFailure: diagnostics.boundedResourceFailure,
            referenceClockDriftPresent: drift != nil,
            referenceClockDriftPPM: drift ?? 0,
            renderSampleCount: renderSamples,
            renderValidSampleCount: renderValid,
            captureSampleCount: captureSamples,
            captureValidSampleCount: captureValid,
            mockAuthorized: seam.authorized,
            mockProcessedFrameCount: seam.processedFrameCount,
            mockFrozenFrameCount: seam.frozenFrameCount,
            mockBoundaryCount: seam.boundaryCount,
            renderBeforeCaptureValid: orderingValid,
            eligibleForAECTrial: eligible)
    }

    var structurallyValid: Bool {
        self.validationReasons().isEmpty
            && !self.synchronizerFailedOpen
            && !self.synchronizerBoundedResourceFailure
            && self.synchronizerOutputFrameCount > 0
            && self.mockAuthorized
            && self.renderBeforeCaptureValid
    }

    func validationReasons() -> [String] {
        var reasons: [String] = []
        if self.schema != Self.schemaVersion { reasons.append("schema") }
        let counts = [
            self.renderAcceptedCallbackCount, self.renderRejectedCallbackCount,
            self.renderGapCount, self.renderOverlapCount, self.renderBackwardCount,
            self.renderDiscontinuityCount, self.renderFormatChangeCount,
            self.captureAcceptedCallbackCount, self.captureRejectedCallbackCount,
            self.captureGapCount, self.captureOverlapCount, self.captureBackwardCount,
            self.captureDiscontinuityCount, self.captureFormatChangeCount,
            self.synchronizerInputFrameCount, self.synchronizerOutputFrameCount,
            self.synchronizerEpochCount, self.synchronizerDroppedFrameCount,
            self.synchronizerDuplicateOrLateFrameCount, self.synchronizerNonFiniteSampleCount,
            self.synchronizerSynthesizedMicrophoneFrameCount, self.renderSampleCount,
            self.renderValidSampleCount, self.captureSampleCount, self.captureValidSampleCount,
            self.mockProcessedFrameCount, self.mockFrozenFrameCount, self.mockBoundaryCount,
        ]
        if !counts.allSatisfy({ (0...Self.maximumCount).contains($0) }) {
            reasons.append("counts")
        }
        let (mockClassifiedCount, mockClassifiedOverflow) =
            self.mockProcessedFrameCount.addingReportingOverflow(self.mockFrozenFrameCount)
        if self.renderValidSampleCount > self.renderSampleCount
            || self.captureValidSampleCount > self.captureSampleCount
            || self.mockProcessedFrameCount > self.synchronizerOutputFrameCount
            || self.mockFrozenFrameCount > self.synchronizerOutputFrameCount
            || self.mockBoundaryCount > self.synchronizerOutputFrameCount
            || mockClassifiedOverflow
            || (self.mockAuthorized
                && mockClassifiedCount != self.synchronizerOutputFrameCount) {
            reasons.append("relationships")
        }
        if !self.referenceClockDriftPPM.isFinite
            || (!self.referenceClockDriftPresent && self.referenceClockDriftPPM != 0) {
            reasons.append("drift")
        }
        if self.eligibleForAECTrial != self.derivedEligibility() {
            reasons.append("eligibility")
        }
        return reasons
    }

    private func derivedEligibility() -> Bool {
        let callbackFaults = [
            self.renderRejectedCallbackCount, self.renderGapCount, self.renderOverlapCount,
            self.renderBackwardCount, self.renderDiscontinuityCount, self.renderFormatChangeCount,
            self.captureRejectedCallbackCount, self.captureGapCount, self.captureOverlapCount,
            self.captureBackwardCount, self.captureDiscontinuityCount,
            self.captureFormatChangeCount,
        ]
        return callbackFaults.allSatisfy { $0 == 0 }
            && !self.synchronizerFailedOpen
            && !self.synchronizerBoundedResourceFailure
            && self.synchronizerDroppedFrameCount == 0
            && self.synchronizerDuplicateOrLateFrameCount == 0
            && self.synchronizerNonFiniteSampleCount == 0
            && self.synchronizerSynthesizedMicrophoneFrameCount == 0
            && self.synchronizerEpochCount == 1
            && self.synchronizerOutputFrameCount > 0
            && self.renderSampleCount == self.renderValidSampleCount
            && self.captureSampleCount == self.captureValidSampleCount
            && self.mockAuthorized
            && self.mockProcessedFrameCount == self.synchronizerOutputFrameCount
            && self.mockFrozenFrameCount == 0
            && self.mockBoundaryCount == 0
            && self.renderBeforeCaptureValid
    }

    private static func boundedSum(_ values: [Int]) -> Int {
        var total = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return Int.max }
            total = sum
        }
        return total
    }

    private static func eventsAreRenderBeforeCapture(_ seam: MeetingStage05MockAECSeamResult) -> Bool {
        guard seam.authorized, !seam.observations.isEmpty else { return false }
        let processedIndices = seam.observations.compactMap {
            $0.adaptationFrozen ? nil : $0.frameIndex
        }
        guard seam.events.count == processedIndices.count * 2 else { return false }
        for (offset, index) in processedIndices.enumerated() {
            let render = seam.events[offset * 2]
            let capture = seam.events[offset * 2 + 1]
            guard render.frameIndex == index, render.kind == .render,
                  capture.frameIndex == index, capture.kind == .capture else { return false }
        }
        return true
    }
}

nonisolated struct MeetingStage05AutorunOutcome: Codable, Equatable, Sendable {
    let exitStatus: Int
    let status: String
    let reason: String?
    let adapter: MeetingStage05LiveAdapterSummary?
}

/// One-shot, DEBUG-only Stage 0.5 evidence capture.  This is intentionally separate from the
/// C2 metadata probe: it retains only the explicitly consented, local lossless WAV artifacts and
/// the metadata-only manifest needed by `MeetingSignalDomainGate`.
nonisolated enum MeetingStage05EvidenceAutorun {
    static let environmentKey = "FLUIDVOICE_STAGE05_EVIDENCE"
    static let autorunEnvironmentKey = "FLUIDVOICE_STAGE05_EVIDENCE_AUTORUN"
    static let consentEnvironmentKey = "FLUIDVOICE_STAGE05_EVIDENCE_CONSENT"
    static let rootEnvironmentKey = "FLUIDVOICE_STAGE05_EVIDENCE_ROOT"
    static let fixturePathEnvironmentKey = "FLUIDVOICE_STAGE05_FIXTURE_PATH"
    static let targetBundleIDEnvironmentKey = "FLUIDVOICE_STAGE05_TARGET_BUNDLE_ID"
    static let operatorMediaConsentEnvironmentKey = "FLUIDVOICE_STAGE05_OPERATOR_MEDIA_CONSENT"
    static let consentToken = "I_CONFIRM_STAGE05_RECORDING_CONSENT"
    static let operatorMediaConsentToken = "I_CONFIRM_OPERATOR_CONTROLLED_WEB_MEDIA"
    static let requiredTargetBundleID = "com.google.Chrome"
    static let expectedFixtureSHA256 = "a102f086a6ba1703c13f6a0707ab78c030a167aecf73f317e7b0b73921be861d"
    static let expectedOperatorMediaFixtureSHA256 = "fbf7a7c40c0a491975de45ff18a7fec7e13135ea01f9821db27f6611ba42eda0"
    static let captureSeconds = 14.0
    static let operatorResponseSeconds = 30.0
    // The declared sub-budgets total forty-eight seconds (30 s operator response + 2 s start
    // + 14 s capture + 2 s stop). Keep a separate, process-level deadline with bounded margin.
    // This does not extend the fourteen-second target or twenty-second frame ceiling.
    static let hardWatchdogSeconds = 56.0

    static func requested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let common = environment[Self.environmentKey] == "1"
            && environment[Self.autorunEnvironmentKey] == "1"
            && environment[Self.consentEnvironmentKey] == Self.consentToken
            && environment[Self.targetBundleIDEnvironmentKey] == Self.requiredTargetBundleID
            && !(environment[Self.rootEnvironmentKey] ?? "").isEmpty
            && !(environment[Self.fixturePathEnvironmentKey] ?? "").isEmpty
        guard common else { return false }
        guard environment[Self.operatorMediaConsentEnvironmentKey] != nil else { return true }
        return Self.operatorMediaRequested(environment: environment)
    }

    static func operatorMediaRequested(environment: [String: String]) -> Bool {
        environment[Self.operatorMediaConsentEnvironmentKey] == Self.operatorMediaConsentToken
    }

    static func autorunEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        self.requested(environment: environment)
            && environment[Self.autorunEnvironmentKey] == "1"
    }

    static func consentConfirmed(environment: [String: String]) -> Bool {
        environment[Self.consentEnvironmentKey] == Self.consentToken
    }

    static func encodedOutcome(
        exitStatus: Int,
        status: String,
        reason: String? = nil,
        adapter: MeetingStage05LiveAdapterSummary? = nil
    ) -> String {
        let validStatus = (exitStatus == 0 && status == "success" && reason == nil)
            || (exitStatus == 1 && status == "failure" && reason?.isEmpty == false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard validStatus, adapter?.validationReasons().isEmpty ?? true,
              let data = try? encoder.encode(MeetingStage05AutorunOutcome(
                  exitStatus: exitStatus, status: status, reason: reason, adapter: adapter)) else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"outcome\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func evidenceRootIsSafe(_ root: URL) -> Bool {
        MeetingStage05PCMCollector.isSafeRoot(root)
    }

    @discardableResult
    static func startIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard self.requested(environment: environment) else { return false }
        let completion = CompletionGate()
        let cleanup = CleanupBox()
        let watchdog = DispatchWorkItem {
            guard completion.claim() else { return }
            cleanup.run()
            print("[STAGE05_EVIDENCE] {\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"deadline\"}")
            fflush(stdout)
            exit(1)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Self.hardWatchdogSeconds, execute: watchdog
        )
        Task { @MainActor in
            let outcome = await Self.run(environment: environment, cleanup: cleanup)
            watchdog.cancel()
            guard completion.claim() else { return }
            print("[STAGE05_EVIDENCE] " + outcome)
            fflush(stdout)
            exit(outcome.contains("\"exitStatus\":0") ? 0 : 1)
        }
        return true
    }

    @MainActor
    private static func run(environment: [String: String], cleanup: CleanupBox) async -> String {
        guard self.autorunEnabled(environment: environment) else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"autorun\"}"
        }
        guard self.consentConfirmed(environment: environment) else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"consent\"}"
        }
        guard CGPreflightScreenCaptureAccess(),
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"permission\"}"
        }
        guard let rootString = environment[Self.rootEnvironmentKey],
              rootString.hasPrefix("/"), !rootString.isEmpty else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"root\"}"
        }
        let operatorMedia = Self.operatorMediaRequested(environment: environment)
        let expectedFixtureSHA256 = operatorMedia
            ? Self.expectedOperatorMediaFixtureSHA256 : Self.expectedFixtureSHA256
        guard let fixtureString = environment[Self.fixturePathEnvironmentKey],
              fixtureString.hasPrefix("/"),
              let fixtureURL = Self.absoluteRegularFile(URL(fileURLWithPath: fixtureString)),
              (try? SHA256Hex.file(fixtureURL)) == expectedFixtureSHA256 else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"fixture\"}"
        }
        guard let target = environment[Self.targetBundleIDEnvironmentKey],
              target == Self.requiredTargetBundleID else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"target\"}"
        }
        guard let input = AudioDevice.getDefaultInputDevice(), input.id != kAudioObjectUnknown, input.isAlive,
              input.isBuiltIn,
              input.inputDataSourceID != AudioDevice.Device.externalMicrophoneDataSourceID,
              let output = AudioDevice.getDefaultOutputDevice(), output.id != kAudioObjectUnknown, output.isAlive,
              output.isBuiltIn, !AudioDevice.outputDataSourceIsHeadphones(output.id),
              let initialVolume = Self.readOutputVolume(output.id), initialVolume > 0, initialVolume <= 0.25,
              MeetingCapturePathDecider.outputRouteDeclineReason(
                  MeetingCaptureEngine.currentOutputRouteSnapshot()) == nil else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"route\"}"
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"shareableContent\"}"
        }
        let windows = Self.windowCandidates(from: content)
        let readyWindow: MeetingExternalReferenceTrialAWindowCandidate
        if operatorMedia {
            let eligibleWindows = content.windows.filter { window in
                guard let owner = window.owningApplication else { return false }
                return Self.operatorMediaWindowIsEligible(
                    windowID: window.windowID,
                    owningBundleIdentifier: owner.bundleIdentifier,
                    owningProcessID: owner.processID,
                    frameWidth: window.frame.width,
                    frameHeight: window.frame.height,
                    targetBundleIdentifier: target)
            }
            guard eligibleWindows.count == 1,
                  let source = eligibleWindows.first,
                  let owner = source.owningApplication else {
                return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"stimulusReady\",\"eligibleWindowCount\":\(eligibleWindows.count)}"
            }
            readyWindow = .init(
                windowID: source.windowID,
                owningBundleIdentifier: owner.bundleIdentifier,
                owningProcessID: owner.processID,
                title: source.title)
        } else {
            guard let selected = MeetingStage05StimulusHandshake.selectReadyWindow(
                from: windows, targetBundleIdentifier: target) else {
                return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"stimulusReady\"}"
            }
            readyWindow = selected
        }
        // This is the only readiness signal emitted by the harness. Flush before polling so the
        // operator can perform the user gesture while the bounded handshake is still open.
        print("[STAGE05_EVIDENCE] {\"status\":\"ready\"}")
        fflush(stdout)
        let selectedSnapshot: PlayingSnapshot
        if operatorMedia {
            // The operator starts the already-selected media after observing the ready marker.
            // Capture setup below takes no title, URL, or playback metadata from the page.
            selectedSnapshot = PlayingSnapshot(candidate: readyWindow, content: content)
        } else {
            do {
                selectedSnapshot = try await Self.awaitPlayingWindow(
                    ready: readyWindow,
                    targetBundleID: target
                )
            } catch let failure as MeetingStage05StimulusHandshake.Failure {
                return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"\(Self.handshakeReason(failure))\"}"
            } catch {
                return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"stimulusTimeout\"}"
            }
        }
        let selectedWindow = selectedSnapshot.candidate
        guard operatorMedia || (Self.remainingStimulusSeconds(selectedWindow.title) != nil) else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"stimulusTime\"}"
        }
        let selectedContent = selectedSnapshot.content
        guard let sourceWindow = selectedContent.windows.first(where: {
                  $0.windowID == selectedWindow.windowID && $0.title == selectedWindow.title
              }),
              let sourceOwner = sourceWindow.owningApplication,
              sourceOwner.bundleIdentifier == target,
              sourceOwner.processID == selectedWindow.owningProcessID,
              selectedContent.applications.contains(where: {
                  $0.bundleIdentifier == target && $0.processID == sourceOwner.processID
              }),
              NSRunningApplication(processIdentifier: sourceOwner.processID)?.isTerminated == false,
              let displayID = MeetingExternalReferenceTrialADisplaySelector.selectDisplayID(
                  windowFrame: sourceWindow.frame,
                  displays: selectedContent.displays.map { .init(displayID: $0.displayID, frame: $0.frame) }
              ), selectedContent.displays.contains(where: { $0.displayID == displayID }) else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"display\"}"
        }

        // Do not call standardizedFileURL here: Foundation canonicalizes /private/tmp to
        // the /tmp symlink alias, while this harness intentionally rejects that alias.
        let root = URL(fileURLWithPath: rootString, isDirectory: true)
        guard root.path == rootString else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"root\"}"
        }
        do {
            try MeetingStage05PCMCollector.prepareRoot(root)
        } catch {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"workspace\"}"
        }
        // Register fixed-name cleanup before the collector can create either WAV.  The watchdog
        // can therefore never strand a partial artifact in a validated evidence root.
        cleanup.set(root: root)
        guard let executableURL = Bundle.main.executableURL.flatMap(Self.absoluteRegularFile),
              let executableSHA256 = try? SHA256Hex.file(executableURL) else {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"build\"}"
        }
        let collector: MeetingStage05PCMCollector
        do {
            collector = try MeetingStage05PCMCollector(root: root, inputUID: input.uid,
                                                       outputUID: output.uid,
                                                       fixtureSHA256: expectedFixtureSHA256,
                                                       executableSHA256: executableSHA256,
                                                       initialOutputVolume: initialVolume,
                                                       targetProcessID: sourceOwner.processID)
        } catch {
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"workspace\"}"
        }
        let filter = SCContentFilter(desktopIndependentWindow: sourceWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3; configuration.showsCursor = false
        configuration.capturesAudio = true; configuration.sampleRate = 48_000
        configuration.channelCount = 1; configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true; configuration.microphoneCaptureDeviceID = input.uid

        let adapter = MeetingStage05SCKFrameAdapter(routeIdentifier: "builtInSpeakerMicrophone")
        let outputHandler = MeetingStage05StreamOutput(collector: collector, adapter: adapter)
        let streamDelegate = MeetingStage05StreamDelegate()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)
        cleanup.set(stream: stream, collector: collector)
        let renderQueue = DispatchQueue(label: "fluidvoice.stage05.render")
        let captureQueue = DispatchQueue(label: "fluidvoice.stage05.capture")
        do {
            try stream.addStreamOutput(outputHandler, type: .audio,
                                       sampleHandlerQueue: renderQueue)
            try stream.addStreamOutput(outputHandler, type: .microphone,
                                       sampleHandlerQueue: captureQueue)
            try await Self.withTimeout(seconds: 2) { try await stream.startCapture() }
            let captureDeadline = ProcessInfo.processInfo.systemUptime + Self.captureSeconds
            while ProcessInfo.processInfo.systemUptime < captureDeadline {
                let remaining = max(0, captureDeadline - ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(nanoseconds: UInt64(min(0.1, remaining) * 1_000_000_000))
                guard Self.routeStillValid(inputUID: input.uid, outputUID: output.uid,
                                           initialVolume: initialVolume,
                                           targetProcessID: sourceOwner.processID) else { throw RouteChanged.error }
            }
            try await Self.withTimeout(seconds: 2) { try await stream.stopCapture() }
            renderQueue.sync {} // Drain callbacks before sealing the WAV headers and manifest.
            captureQueue.sync {}
            guard Self.routeStillValid(inputUID: input.uid, outputUID: output.uid,
                                       initialVolume: initialVolume,
                                       targetProcessID: sourceOwner.processID),
                  let finalOutput = AudioDevice.getDefaultOutputDevice(),
                  finalOutput.uid == output.uid,
                  Self.readOutputVolume(finalOutput.id) != nil,
                  streamDelegate.errorCount == 0 else {
                collector.abort()
                return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"routeChanged\"}"
            }
        } catch {
            try? await Self.withTimeout(seconds: 2) { try await stream.stopCapture() }
            collector.abort()
            return "{\"exitStatus\":1,\"status\":\"failure\",\"reason\":\"capture\"}"
        }
        // Both callback queues are drained above. From this point the adapter is immutable:
        // synchronize exactly once, then exercise the identity/mock AEC seam exactly once.
        let (adapterDrain, synchronization) = adapter.synchronize(configuration: .init(
            referenceScope: .selectedWindow,
            referenceCompleteness: .measuredComplete))
        let seam = MeetingStage05MockAECSeam().process(synchronization)
        let adapterSummary = MeetingStage05LiveAdapterSummary.make(
            drain: adapterDrain, synchronization: synchronization, seam: seam)
        guard adapterSummary.structurallyValid else {
            collector.abort()
            return Self.encodedOutcome(
                exitStatus: 1, status: "failure", reason: "adapterGate",
                adapter: adapterSummary.validationReasons().isEmpty ? adapterSummary : nil)
        }
        do {
            guard let finalOutput = AudioDevice.getDefaultOutputDevice(),
                  finalOutput.uid == output.uid,
                  let finalVolume = Self.readOutputVolume(finalOutput.id) else {
                throw RouteChanged.error
            }
            try collector.finish(consentConfirmed: true, finalOutputVolume: finalVolume)
            return Self.encodedOutcome(
                exitStatus: 0, status: "success", adapter: adapterSummary)
        } catch let failure as MeetingStage05FinalizeFailure {
            // Only completed render/capture timing finalization retains the numeric-only
            // timing.json; all other failure categories retain nothing.
            if failure == .renderTiming || failure == .captureTiming {
                collector.retainTimingFailureRecord(failure)
            } else {
                collector.abort()
            }
            return Self.encodedOutcome(
                exitStatus: 1, status: "failure", reason: "finalize\(failure.rawValue)",
                adapter: adapterSummary)
        } catch {
            collector.abort()
            return Self.encodedOutcome(
                exitStatus: 1, status: "failure", reason: "finalizeUnknown",
                adapter: adapterSummary)
        }
    }

    private static func readOutputVolume(_ deviceID: AudioObjectID) -> Float32? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var value: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
               value.isFinite, (0...1).contains(value) { return value }
        }
        return nil
    }

    private static func windowCandidates(from content: SCShareableContent) -> [MeetingExternalReferenceTrialAWindowCandidate] {
        content.windows.compactMap { window in
            guard let owner = window.owningApplication else { return nil }
            return .init(windowID: window.windowID, owningBundleIdentifier: owner.bundleIdentifier,
                         owningProcessID: owner.processID, title: window.title)
        }
    }

    static func operatorMediaWindowIsEligible(
        windowID: CGWindowID,
        owningBundleIdentifier: String,
        owningProcessID: Int32,
        frameWidth: CGFloat,
        frameHeight: CGFloat,
        targetBundleIdentifier: String
    ) -> Bool {
        windowID != 0
            && owningBundleIdentifier == targetBundleIdentifier
            && owningProcessID > 0
            && frameWidth.isFinite && frameWidth >= 640
            && frameHeight.isFinite && frameHeight >= 360
    }

    private struct PlayingSnapshot {
        let candidate: MeetingExternalReferenceTrialAWindowCandidate
        let content: SCShareableContent
    }

    private static func awaitPlayingWindow(
        ready: MeetingExternalReferenceTrialAWindowCandidate,
        targetBundleID: String
    ) async throws -> PlayingSnapshot {
        // This is an operator-response window only: no stream or audio capture has
        // started yet. Leave enough time for the external controller to observe the
        // ready marker and click the fixture while keeping the whole one-shot run
        // inside the independent 56-second process watchdog.
        let deadline = ProcessInfo.processInfo.systemUptime + Self.operatorResponseSeconds
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            guard now.isFinite, now < deadline else {
                throw MeetingStage05StimulusHandshake.Failure.timeout
            }
            let content: SCShareableContent
            do {
                content = try await Self.withTimeout(seconds: min(0.5, max(0.01, deadline - now))) {
                    try await SCShareableContent.current
                }
            } catch {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    throw MeetingStage05StimulusHandshake.Failure.timeout
                }
                continue
            }
            let decision = MeetingStage05StimulusHandshake.decision(
                for: ready, current: Self.windowCandidates(from: content),
                targetBundleIdentifier: targetBundleID,
                now: ProcessInfo.processInfo.systemUptime, deadline: deadline)
            switch decision {
            case .success(let playing): return PlayingSnapshot(candidate: playing, content: content)
            case .failure(let failure): throw failure
            case .waiting:
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw MeetingStage05StimulusHandshake.Failure.timeout }
                try await Task.sleep(nanoseconds: UInt64(min(0.1, remaining) * 1_000_000_000))
            }
        }
    }

    private static func handshakeReason(_ failure: MeetingStage05StimulusHandshake.Failure) -> String {
        switch failure {
        case .ambiguous: return "stimulusAmbiguous"
        case .ownerChanged: return "stimulusOwnerChanged"
        case .processChanged: return "stimulusProcessChanged"
        case .windowChanged: return "stimulusWindowChanged"
        case .malformedState: return "stimulusMalformed"
        case .remainingInsufficient: return "stimulusTime"
        case .timeout: return "stimulusTimeout"
        }
    }
    private static func routeStillValid(inputUID: String, outputUID: String, initialVolume: Float32,
                                        targetProcessID: Int32) -> Bool {
        guard NSRunningApplication(processIdentifier: targetProcessID)?.isTerminated == false else {
            return false
        }
        guard let input = AudioDevice.getDefaultInputDevice(), input.uid == inputUID,
              input.isAlive, input.isBuiltIn,
              input.inputDataSourceID != AudioDevice.Device.externalMicrophoneDataSourceID,
              let output = AudioDevice.getDefaultOutputDevice(), output.uid == outputUID,
              output.isAlive, output.isBuiltIn, !AudioDevice.outputDataSourceIsHeadphones(output.id),
              let volume = readOutputVolume(output.id), volume > 0, volume <= 0.25,
              abs(volume - initialVolume) <= 0.0001,
              MeetingCapturePathDecider.outputRouteDeclineReason(MeetingCaptureEngine.currentOutputRouteSnapshot()) == nil else { return false }
        return true
    }

    private static func absoluteRegularFile(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/"), !url.path.contains("/Library/CloudStorage/"),
              !url.path.contains("/Mobile Documents/"), (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil { return nil }
        }
        return url
    }
    static func remainingStimulusSeconds(_ title: String?) -> Double? {
        guard let value = MeetingStage05StimulusHandshake.playingRemainingSeconds(title),
              value >= Double(MeetingStage05StimulusHandshake.minimumRemainingSeconds) else { return nil }
        return value
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !done else { return false }; done = true; return true }
    }

    private final class CleanupBox: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (() -> Void)?

        func set(root: URL) {
            self.lock.lock()
            self.action = { MeetingStage05PCMCollector.emergencyCleanup(at: root) }
            self.lock.unlock()
        }

        func set(stream: SCStream, collector: MeetingStage05PCMCollector) {
            self.lock.lock()
            self.action = {
                // Completion-handler API is intentionally non-blocking on the hard-deadline path.
                stream.stopCapture { _ in }
                collector.emergencyCleanup()
            }
            self.lock.unlock()
        }

        func run() { lock.lock(); let action = self.action; self.action = nil; lock.unlock(); action?() }
    }

    enum TimeoutError: Error { case timeout }
    private enum RouteChanged: Error { case error }
    static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds.isFinite, seconds > 0 else { throw TimeoutError.timeout }
        return try await withCheckedThrowingContinuation { continuation in
            let race = TimeoutContinuation(continuation)
            // These are deliberately unstructured. A structured task group waits for a child
            // that ignores cancellation, defeating the timeout for ScreenCaptureKit operations.
            Task {
                do { race.resolve(.success(try await operation())) }
                catch { race.resolve(.failure(error)) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                race.resolve(.failure(TimeoutError.timeout))
            }
        }
    }

    private final class TimeoutContinuation<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?

        init(_ continuation: CheckedContinuation<Value, any Error>) {
            self.continuation = continuation
        }

        func resolve(_ result: Result<Value, any Error>) {
            self.lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(with: result)
        }
    }
}

final class MeetingStage05StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let collector: MeetingStage05PCMCollector
    private let adapter: MeetingStage05SCKFrameAdapter
    private let monotonicNow: @Sendable () -> Double

    init(
        collector: MeetingStage05PCMCollector,
        adapter: MeetingStage05SCKFrameAdapter,
        monotonicNow: @escaping @Sendable () -> Double = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.collector = collector
        self.adapter = adapter
        self.monotonicNow = monotonicNow
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        self.handle(sampleBuffer, outputType: outputType)
    }

    /// Testable callback boundary. The monotonic clock is sampled once for each audio callback
    /// and the same value is passed to both the WAV timing collector and live adapter.
    func handle(_ sampleBuffer: CMSampleBuffer, outputType: SCStreamOutputType) {
        let output: MeetingStage05PCMCollector.Output
        switch outputType {
        case .audio: output = .render
        case .microphone: output = .capture
        default: return
        }
        let arrivalSeconds = self.monotonicNow()
        self.collector.append(sampleBuffer, output: output, arrivalSeconds: arrivalSeconds)
        switch output {
        case .render:
            self.adapter.appendRender(sampleBuffer, arrivalSeconds: arrivalSeconds)
        case .capture:
            self.adapter.appendMicrophone(sampleBuffer, arrivalSeconds: arrivalSeconds)
        }
    }
}

private final class MeetingStage05StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock(); private var errors = 0
    var errorCount: Int { lock.lock(); defer { lock.unlock() }; return errors }
    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.lock(); errors += 1; lock.unlock() }
}

nonisolated struct MeetingStage05NativePCMFormat: Equatable, Sendable {
    let codec: String
    let bytesPerFrame: Int
    let bitsPerChannel: Int

    static func from(_ asbd: AudioStreamBasicDescription) -> Self? {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate == 48_000,
              asbd.mChannelsPerFrame == 1,
              asbd.mFramesPerPacket == 1,
              asbd.mBytesPerPacket == asbd.mBytesPerFrame,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0 else { return nil }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat, asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0,
              asbd.mBitsPerChannel == 32, asbd.mBytesPerFrame == 4 else { return nil }
        return .init(codec: "pcm_f32le", bytesPerFrame: 4, bitsPerChannel: 32)
    }

    static func containsOnlyFiniteFloat32(_ data: Data) -> Bool {
        guard data.count.isMultiple(of: 4) else { return false }
        return data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: UInt32.self).allSatisfy {
                Float32(bitPattern: UInt32(littleEndian: $0)).isFinite
            }
        }
    }
}

/// Privacy-safe finalization categories. These values describe only which invariant failed;
/// they never include samples, device identifiers, paths, titles, or measured values.
nonisolated enum MeetingStage05FinalizeFailure: String, Error, CaseIterable, Sendable {
    case appendInvalidFrame = "AppendInvalidFrame"
    case appendFormatChanged = "AppendFormatChanged"
    case appendSampleRateChanged = "AppendSampleRateChanged"
    case appendFrameLimit = "AppendFrameLimit"
    case appendBlockLimit = "AppendBlockLimit"
    case appendWrite = "AppendWrite"
    case missingStream = "MissingStream"
    case renderTiming = "RenderTiming"
    case captureTiming = "CaptureTiming"
    case renderSilent = "RenderSilent"
    case renderOutOfBounds = "RenderOutOfBounds"
    case captureNonfinite = "CaptureNonfinite"
    case captureClipping = "CaptureClipping"
    case renderSeal = "RenderSeal"
    case captureSeal = "CaptureSeal"
    case artifact = "Artifact"
    case provenance = "Provenance"
    case manifest = "Manifest"
}

/// Privacy-safe, versioned, numeric-only record retained exclusively for completed
/// render/capture timing finalization failures. Never add PCM, peaks, hashes, identifiers,
/// titles, paths, labels, transcripts, or provenance fields here.
nonisolated struct MeetingStage05TimingFailureRecord: Codable, Equatable, Sendable {
    static let schema = "fv-stage05-timing-failure-v1"
    static let filename = "timing.json"

    nonisolated struct Track: Codable, Equatable, Sendable {
        let blocks: [MeetingSignalDomainGateManifest.TimingBlock]
        let gapCount: Int
        let overlapCount: Int
        let backwardCount: Int
        let formatChangeCount: Int
    }

    let schema: String
    let failure: String
    let track: String
    let sampleRateHz: Double
    let render: Track
    let capture: Track

    static func make(
        failure: MeetingStage05FinalizeFailure,
        renderTiming: [MeetingSignalDomainGateManifest.TimingBlock],
        captureTiming: [MeetingSignalDomainGateManifest.TimingBlock],
        sampleRateHz: Double
    ) -> Self {
        Self(schema: Self.schema, failure: failure.rawValue,
             track: failure == .renderTiming ? "render" : "capture",
             sampleRateHz: sampleRateHz,
             render: Self.derive(renderTiming, sampleRateHz: sampleRateHz),
             capture: Self.derive(captureTiming, sampleRateHz: sampleRateHz))
    }

    private static func derive(
        _ blocks: [MeetingSignalDomainGateManifest.TimingBlock], sampleRateHz: Double
    ) -> Track {
        let tolerance = 1 / sampleRateHz
        var gaps = 0
        var overlaps = 0
        var backward = 0
        for pair in zip(blocks.dropFirst(), blocks) {
            let delta = pair.0.presentationSeconds - (pair.1.presentationSeconds + pair.1.durationSeconds)
            if delta > tolerance { gaps += 1 }
            if delta < -tolerance { overlaps += 1 }
            if pair.0.presentationSeconds <= pair.1.presentationSeconds { backward += 1 }
        }
        // A format change aborts the run before timing finalization, so a retained record
        // can only ever observe zero format transitions.
        return Track(blocks: blocks, gapCount: gaps, overlapCount: overlaps,
                     backwardCount: backward, formatChangeCount: 0)
    }

    func validationReasons() -> [String] {
        var reasons: [String] = []
        if schema != Self.schema { reasons.append("schema") }
        let timingFailures: Set<String> = [
            MeetingStage05FinalizeFailure.renderTiming.rawValue,
            MeetingStage05FinalizeFailure.captureTiming.rawValue,
        ]
        if !timingFailures.contains(failure) { reasons.append("failure") }
        let expectedTrack = failure == MeetingStage05FinalizeFailure.renderTiming.rawValue
            ? "render" : "capture"
        if track != expectedTrack { reasons.append("track") }
        if !sampleRateHz.isFinite || sampleRateHz != 48_000 { reasons.append("sampleRateHz") }
        for side in [render, capture] {
            if side.blocks.isEmpty || side.blocks.count > 2_000 { reasons.append("blockCount") }
            var totalFrames = 0
            for block in side.blocks {
                if !block.presentationSeconds.isFinite || block.presentationSeconds < 0
                    || !block.durationSeconds.isFinite || block.durationSeconds <= 0
                    || block.frameCount <= 0
                    || (block.arrivalSeconds.map { !$0.isFinite || $0 < 0 } ?? false) {
                    reasons.append("block")
                    break
                }
                let (next, overflow) = totalFrames.addingReportingOverflow(block.frameCount)
                if overflow { reasons.append("frameCount"); totalFrames = Int.max; break }
                totalFrames = next
            }
            if totalFrames > 960_000 { reasons.append("frameCount") }
            if side.gapCount < 0 || side.overlapCount < 0 || side.backwardCount < 0
                || side.formatChangeCount < 0 { reasons.append("counts") }
            if sampleRateHz.isFinite, sampleRateHz > 0,
               side != Self.derive(side.blocks, sampleRateHz: sampleRateHz) {
                reasons.append("derivedCounts")
            }
        }
        return reasons
    }
}

final class MeetingStage05PCMCollector: @unchecked Sendable {
    enum Output { case render, capture }
    private let root: URL
    private let inputUID: String
    private let outputUID: String
    private let fixtureSHA256: String
    private let executableSHA256: String
    private let initialOutputVolume: Float32
    private let targetProcessID: Int32
    private let lock = NSLock()
    private var render: WAVWriter
    private var capture: WAVWriter
    private var aborted = false
    private var renderTiming: [MeetingSignalDomainGateManifest.TimingBlock] = []
    private var captureTiming: [MeetingSignalDomainGateManifest.TimingBlock] = []
    private var nativeSampleRateHz: Double?
    private var appendFailure: MeetingStage05FinalizeFailure?
    private let maxBlocks = 2_000
    private let maxFrames = 960_000

    init(
        root: URL,
        inputUID: String,
        outputUID: String,
        fixtureSHA256: String,
        executableSHA256: String,
        initialOutputVolume: Float32,
        targetProcessID: Int32
    ) throws {
        self.root = root
        self.inputUID = inputUID; self.outputUID = outputUID
        self.fixtureSHA256 = fixtureSHA256
        self.executableSHA256 = executableSHA256
        self.initialOutputVolume = initialOutputVolume
        self.targetProcessID = targetProcessID
        try Self.prepareRoot(self.root)
        let manager = FileManager.default
        let renderURL = self.root.appendingPathComponent("render.wav")
        let captureURL = self.root.appendingPathComponent("capture.wav")
        guard !manager.fileExists(atPath: renderURL.path), !manager.fileExists(atPath: captureURL.path),
              !manager.fileExists(atPath: self.root.appendingPathComponent("manifest.json").path) else { throw Error.workspace }
        let renderWriter = try WAVWriter(url: renderURL)
        do {
            let captureWriter = try WAVWriter(url: captureURL)
            self.render = renderWriter
            self.capture = captureWriter
        } catch {
            renderWriter.discard()
            try? manager.removeItem(at: captureURL)
            throw error
        }
    }

    static func prepareRoot(_ root: URL) throws {
        guard Self.isSafeRoot(root) else { throw Error.workspace }
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            guard (try? manager.destinationOfSymbolicLink(atPath: root.path)) == nil,
                  (try? manager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory else { throw Error.workspace }
            let mode = (try? manager.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard mode & 0o777 == 0o700 else { throw Error.workspace }
        } else {
            try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        let rootAttributes = try manager.attributesOfItem(atPath: root.path)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory,
              (rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (try manager.contentsOfDirectory(atPath: root.path)).isEmpty else {
            throw Error.workspace
        }
    }

    static func isSafeRoot(_ root: URL) -> Bool {
        let path = root.path
        guard root.isFileURL,
              root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix("fv-stage05-evidence."),
              root.lastPathComponent.count > "fv-stage05-evidence.".count,
              path == "/private/tmp/\(root.lastPathComponent)" else { return false }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil { return false }
        }
        return true
    }

    func append(
        _ sampleBuffer: CMSampleBuffer,
        output: Output,
        arrivalSeconds: Double? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        guard !aborted else { return }
        let callbackArrival = arrivalSeconds ?? ProcessInfo.processInfo.systemUptime
        guard let frame = Self.extract(sampleBuffer, arrivalSeconds: callbackArrival), frame.frameCount > 0,
              frame.sampleRateHz > 0, frame.channels == 1,
              frame.frameCount <= maxFrames else { failAppend(.appendInvalidFrame); return }
        if let existing = render.format ?? capture.format, existing != frame.format {
            failAppend(.appendFormatChanged); return
        }
        if let nativeSampleRateHz, abs(nativeSampleRateHz - frame.sampleRateHz) > 1e-6 {
            failAppend(.appendSampleRateChanged); return
        }
        nativeSampleRateHz = frame.sampleRateHz
        switch output {
        case .render: if render.frameCount + frame.frameCount > maxFrames { failAppend(.appendFrameLimit); return }
        case .capture: if capture.frameCount + frame.frameCount > maxFrames { failAppend(.appendFrameLimit); return }
        }
        let timing = MeetingSignalDomainGateManifest.TimingBlock(
            presentationSeconds: frame.presentationSeconds, durationSeconds: frame.durationSeconds,
            frameCount: frame.frameCount, arrivalSeconds: frame.arrivalSeconds)
        do {
            switch output {
            case .render:
                guard renderTiming.count < maxBlocks else { failAppend(.appendBlockLimit); return }
                try render.append(frame.data, format: frame.format, sampleRateHz: frame.sampleRateHz, frameCount: frame.frameCount)
                renderTiming.append(timing)
            case .capture:
                guard captureTiming.count < maxBlocks else { failAppend(.appendBlockLimit); return }
                try capture.append(frame.data, format: frame.format, sampleRateHz: frame.sampleRateHz, frameCount: frame.frameCount)
                captureTiming.append(timing)
            }
        } catch { failAppend(.appendWrite) }
    }

    private func failAppend(_ failure: MeetingStage05FinalizeFailure) {
        if appendFailure == nil { appendFailure = failure }
        aborted = true
    }

    func finish(consentConfirmed: Bool, finalOutputVolume: Float32) throws {
        lock.lock(); defer { lock.unlock() }
        if aborted { throw appendFailure ?? MeetingStage05FinalizeFailure.appendInvalidFrame }
        guard consentConfirmed, !renderTiming.isEmpty, !captureTiming.isEmpty else {
            throw MeetingStage05FinalizeFailure.missingStream
        }
        guard Self.timingIsComplete(renderTiming, frameCount: render.frameCount,
                                    sampleRateHz: render.sampleRateHz) else {
            throw MeetingStage05FinalizeFailure.renderTiming
        }
        guard Self.timingIsComplete(captureTiming, frameCount: capture.frameCount,
                                    sampleRateHz: capture.sampleRateHz) else {
            throw MeetingStage05FinalizeFailure.captureTiming
        }
        guard render.peak > 0 else { throw MeetingStage05FinalizeFailure.renderSilent }
        guard render.peak <= 0.15 else { throw MeetingStage05FinalizeFailure.renderOutOfBounds }
        guard capture.peak.isFinite else { throw MeetingStage05FinalizeFailure.captureNonfinite }
        guard capture.peak <= 1 else { throw MeetingStage05FinalizeFailure.captureClipping }
        do { try render.finish() } catch { throw MeetingStage05FinalizeFailure.renderSeal }
        do { try capture.finish() } catch { throw MeetingStage05FinalizeFailure.captureSeal }
        let renderArtifact: MeetingSignalDomainGateManifest.Artifact
        let captureArtifact: MeetingSignalDomainGateManifest.Artifact
        do {
            renderArtifact = try Self.artifact(role: "render", url: render.url, writer: render)
            captureArtifact = try Self.artifact(role: "capture", url: capture.url, writer: capture)
        } catch { throw MeetingStage05FinalizeFailure.artifact }
        let session = MeetingSignalDomainGateManifest.Session(
            ordinal: 0, render: renderArtifact, capture: captureArtifact,
            renderTiming: renderTiming, captureTiming: captureTiming)
        let provenance = MeetingStage05Provenance(
            renderSHA256: renderArtifact.sha256, captureSHA256: captureArtifact.sha256,
            fixtureSHA256: fixtureSHA256, captureExecutableSHA256: executableSHA256,
            inputUIDSHA256: SHA256Hex.string(inputUID), outputUIDSHA256: SHA256Hex.string(outputUID),
            runOrdinal: 0, targetProcessID: targetProcessID,
            initialOutputVolume: initialOutputVolume, finalOutputVolume: finalOutputVolume,
            renderPeak: render.peak, capturePeak: capture.peak,
            renderBlockCount: renderTiming.count, captureBlockCount: captureTiming.count,
            renderFrameCount: render.frameCount, captureFrameCount: capture.frameCount)
        let provenanceData: Data
        do { provenanceData = try JSONEncoder.sorted.encode(provenance) }
        catch { throw MeetingStage05FinalizeFailure.provenance }
        let provenanceURL = root.appendingPathComponent("provenance.json")
        let provenanceDescriptor = Darwin.open(provenanceURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard provenanceDescriptor >= 0 else { throw MeetingStage05FinalizeFailure.provenance }
        let provenanceHandle = FileHandle(fileDescriptor: provenanceDescriptor, closeOnDealloc: true)
        do {
            try provenanceHandle.write(contentsOf: provenanceData)
            try provenanceHandle.synchronize(); try provenanceHandle.close()
        } catch { throw MeetingStage05FinalizeFailure.provenance }
        let provenanceHash: String
        do { provenanceHash = try SHA256Hex.file(provenanceURL) }
        catch { throw MeetingStage05FinalizeFailure.provenance }
        let manifest = MeetingSignalDomainGateManifest(
            topology: .pairedScreenCaptureKit, route: .builtInSpeakerMicrophone,
            referenceScope: .selectedWindow, referenceCompletenessMeasured: true,
            consentConfirmed: consentConfirmed, artifacts: [], sessions: [session],
            provenanceRelativePath: "provenance.json", provenanceSha256: provenanceHash)
        guard manifest.validationReasons().isEmpty else { throw MeetingStage05FinalizeFailure.manifest }
        let data: Data
        do { data = try JSONEncoder.sorted.encode(manifest) }
        catch { throw MeetingStage05FinalizeFailure.manifest }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let descriptor = Darwin.open(manifestURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw MeetingStage05FinalizeFailure.manifest }
        let manifestHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try manifestHandle.write(contentsOf: data)
            try manifestHandle.synchronize(); try manifestHandle.close()
        } catch { throw MeetingStage05FinalizeFailure.manifest }
    }

    func abort() {
        lock.lock(); aborted = true
        render.discard(); capture.discard()
        let manager = FileManager.default
        try? manager.removeItem(at: root.appendingPathComponent("manifest.json"))
        try? manager.removeItem(at: root.appendingPathComponent("provenance.json"))
        try? manager.removeItem(at: root.appendingPathComponent(MeetingStage05TimingFailureRecord.filename))
        lock.unlock()
    }

    /// Retains only the numeric timing-failure record for a completed render/capture timing
    /// finalization failure. Both WAVs, the manifest, and the provenance sidecar are closed
    /// and unlinked first, so successful WAV evidence and a timing-only failure record are
    /// mutually exclusive. Every other failure category retains nothing.
    func retainTimingFailureRecord(_ failure: MeetingStage05FinalizeFailure) {
        lock.lock(); defer { lock.unlock() }
        aborted = true
        render.discard(); capture.discard()
        let manager = FileManager.default
        try? manager.removeItem(at: root.appendingPathComponent("manifest.json"))
        try? manager.removeItem(at: root.appendingPathComponent("provenance.json"))
        guard failure == .renderTiming || failure == .captureTiming else {
            try? manager.removeItem(at: root.appendingPathComponent(MeetingStage05TimingFailureRecord.filename))
            return
        }
        let record = MeetingStage05TimingFailureRecord.make(
            failure: failure, renderTiming: renderTiming, captureTiming: captureTiming,
            sampleRateHz: nativeSampleRateHz ?? 48_000)
        guard record.validationReasons().isEmpty,
              let data = try? JSONEncoder.sorted.encode(record) else {
            Self.emergencyCleanup(at: root)
            return
        }
        let url = root.appendingPathComponent(MeetingStage05TimingFailureRecord.filename)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            // A pre-existing record means the root is in an inconsistent state; retain nothing.
            Self.emergencyCleanup(at: root)
            return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            Self.emergencyCleanup(at: root)
        }
    }

    /// Emergency path intentionally avoids the collector lock. The watchdog has a hard deadline;
    /// it unlinks only these fixed private filenames and then terminates the process.
    nonisolated func emergencyCleanup() {
        Self.emergencyCleanup(at: root)
    }

    nonisolated static func emergencyCleanup(at root: URL) {
        for name in ["render.wav", "capture.wav", "manifest.json", "provenance.json",
                     MeetingStage05TimingFailureRecord.filename] {
            root.appendingPathComponent(name).path.withCString { _ = Darwin.unlink($0) }
        }
    }

    private static func artifact(role: String, url: URL, writer: WAVWriter) throws -> MeetingSignalDomainGateManifest.Artifact {
        let hash = try SHA256Hex.file(url)
        guard let codec = writer.codec else { throw MeetingStage05PCMCollector.Error.invalidCapture }
        return .init(role: role, relativePath: role + ".wav", sha256: hash, codec: codec,
                     lossless: true, sampleRateHz: writer.sampleRateHz, channelCount: 1,
                     durationSeconds: Double(writer.frameCount) / writer.sampleRateHz)
    }

    private static func timingIsComplete(_ blocks: [MeetingSignalDomainGateManifest.TimingBlock],
                                         frameCount: Int, sampleRateHz: Double) -> Bool {
        guard blocks.count >= 3, blocks.allSatisfy({ $0.arrivalSeconds != nil }),
              blocks.reduce(0, { $0 + $1.frameCount }) == frameCount else { return false }
        let tolerance = 1 / sampleRateHz
        for pair in zip(blocks.dropFirst(), blocks) {
            let difference = pair.0.presentationSeconds - (pair.1.presentationSeconds + pair.1.durationSeconds)
            if abs(difference) > tolerance || pair.0.arrivalSeconds! < pair.1.arrivalSeconds! { return false }
        }
        guard let first = blocks.first, let last = blocks.last else { return false }
        let span = last.presentationSeconds + last.durationSeconds - first.presentationSeconds
        let covered = blocks.reduce(0) { $0 + $1.durationSeconds }
        return span > 0 && covered / span >= 0.99 && covered >= 4.5
    }

    private struct Frame {
        let data: Data
        let presentationSeconds: Double
        let durationSeconds: Double
        let frameCount: Int
        let sampleRateHz: Double
        let channels: Int
        let format: String
        let arrivalSeconds: Double
    }
    private static func extract(_ sampleBuffer: CMSampleBuffer, arrivalSeconds: Double) -> Frame? {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let nativeFormat = MeetingStage05NativePCMFormat.from(asbd) else { return nil }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        guard count > 0, pts.isFinite, duration.isFinite, duration > 0,
              arrivalSeconds.isFinite, arrivalSeconds >= 0 else { return nil }
        let byteCount = count * nativeFormat.bytesPerFrame
        var requiredSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &requiredSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil) == noErr, requiredSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: requiredSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retained) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count == 1, buffers[0].mNumberChannels == 1,
              buffers[0].mDataByteSize == UInt32(byteCount), let pointer = buffers[0].mData else { return nil }
        let data = Data(bytes: pointer, count: byteCount)
        if nativeFormat.codec == "pcm_f32le" {
            guard MeetingStage05NativePCMFormat.containsOnlyFiniteFloat32(data) else { return nil }
        }
        return .init(data: data, presentationSeconds: pts, durationSeconds: duration,
                     frameCount: count, sampleRateHz: asbd.mSampleRate, channels: 1,
                     format: nativeFormat.codec, arrivalSeconds: arrivalSeconds)
    }

    enum Error: Swift.Error { case workspace, invalidCapture }
}

private final class WAVWriter {
    let url: URL
    private let handle: FileHandle
    private(set) var sampleRateHz = 48_000.0
    private(set) var frameCount = 0
    private(set) var codec: String?
    private(set) var peak: Float = 0
    var format: String? { codec }
    init(url: URL) throws {
        self.url = url
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw MeetingStage05PCMCollector.Error.workspace }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try self.handle.write(contentsOf: Data(repeating: 0, count: 44))
    }
    func append(_ data: Data, format: String, sampleRateHz: Double, frameCount: Int) throws {
        let bytesPerSample = 4
        guard format == "pcm_f32le" else { throw MeetingStage05PCMCollector.Error.invalidCapture }
        guard sampleRateHz.isFinite, sampleRateHz > 0, data.count == frameCount * bytesPerSample,
              self.codec == nil || self.codec == format else { throw MeetingStage05PCMCollector.Error.invalidCapture }
        let values = data.withUnsafeBytes { $0.bindMemory(to: UInt32.self).map { Float32(bitPattern: UInt32(littleEndian: $0)) } }
        guard values.allSatisfy(\.isFinite) else { throw MeetingStage05PCMCollector.Error.invalidCapture }
        self.peak = max(self.peak, values.map { abs($0) }.max() ?? 0)
        self.codec = format; self.sampleRateHz = sampleRateHz; self.frameCount += frameCount
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    func finish() throws {
        guard let codec else { throw MeetingStage05PCMCollector.Error.invalidCapture }
        let (formatTag, bits): (UInt16, UInt16) = (3, 32)
        let bytesPerSample = Int(bits / 8)
        guard codec == "pcm_f32le" else { throw MeetingStage05PCMCollector.Error.invalidCapture }
        var header = Data(); header.append(contentsOf: Array("RIFF".utf8)); header.appendLE(UInt32(36 + frameCount * bytesPerSample)); header.append(contentsOf: Array("WAVEfmt ".utf8)); header.appendLE(UInt32(16)); header.appendLE(formatTag); header.appendLE(UInt16(1)); header.appendLE(UInt32(sampleRateHz.rounded())); header.appendLE(UInt32(sampleRateHz.rounded() * Double(bytesPerSample))); header.appendLE(UInt16(bytesPerSample)); header.appendLE(bits); header.append(contentsOf: Array("data".utf8)); header.appendLE(UInt32(frameCount * bytesPerSample))
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header); try handle.synchronize(); try handle.close()
    }
    func discard() { try? handle.close(); try? FileManager.default.removeItem(at: url) }
}

private struct MeetingStage05Provenance: Codable {
    let renderSHA256: String; let captureSHA256: String; let fixtureSHA256: String
    let captureExecutableSHA256: String
    let inputUIDSHA256: String; let outputUIDSHA256: String
    let runOrdinal: Int; let targetProcessID: Int32
    let initialOutputVolume: Float32; let finalOutputVolume: Float32
    let renderPeak: Float; let capturePeak: Float
    let renderBlockCount: Int; let captureBlockCount: Int
    let renderFrameCount: Int; let captureFrameCount: Int
    var osBuildIdentity = ProcessInfo.processInfo.operatingSystemVersionString
    var appBuildIdentity = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    var captureConfiguration = "SCStream:48kHz:mono:native-f32le:audio+microphone"
    var route = "builtInSpeakerMicrophone"
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) } }
}

private enum SHA256Hex {
    static func file(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        throw MeetingStage05PCMCollector.Error.invalidCapture
        #endif
    }

    static func string(_ value: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}

#endif
