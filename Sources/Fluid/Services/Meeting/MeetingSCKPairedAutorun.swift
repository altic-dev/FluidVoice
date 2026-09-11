#if DEBUG

import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

/// DEBUG-only installed-app entry point for the C2 measurement. It is deliberately isolated from
/// AppServices and the meeting coordinator: the only retained state is aggregate numeric metadata.
nonisolated enum MeetingSCKPairedAutorun {
    private static let captureDurationSeconds = 5.0
    static let maximumRunSeconds = 12.0
    static let hardWatchdogSeconds = 14.0
    private static let operationTimeoutSeconds = 2.0
    private static let hardWatchdogFailureLine =
        "[C2_AUTORUN] {\"exitStatus\":1,\"reason\":\"C2 autorun exceeded its hard deadline\",\"status\":\"failure\"}"

    @discardableResult
    static func startIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard MeetingSCKPairedDiagnosticGate.autorunEnabled(environment: environment) else {
            return false
        }
        let completionGate = CompletionGate()
        let watchdog = DispatchWorkItem {
            guard completionGate.claim() else { return }
            print(Self.hardWatchdogFailureLine)
            fflush(stdout)
            Darwin.exit(1)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Self.hardWatchdogSeconds,
            execute: watchdog
        )
        Task { @MainActor in
            let outcome: Outcome
            do {
                outcome = try await Self.withTimeout(seconds: Self.maximumRunSeconds) {
                    await Self.run(environment: environment)
                }
            } catch is CancellationError {
                outcome = Self.failure("C2 autorun was cancelled")
            } catch {
                outcome = Self.failure("C2 autorun exceeded its time limit")
            }
            watchdog.cancel()
            guard completionGate.claim() else { return }
            print("[C2_AUTORUN] " + outcome.line)
            fflush(stdout)
            Darwin.exit(outcome.exitStatus)
        }
        return true
    }

    private struct Outcome: Sendable {
        let exitStatus: Int32
        let line: String
    }

    @MainActor
    private static func run(environment: [String: String]) async -> Outcome {
        guard CGPreflightScreenCaptureAccess() else {
            return Self.failure("screen recording access is not preflight-authorized")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return Self.failure("microphone access is not authorized")
        }
        guard let bundleID = environment[MeetingSCKPairedDiagnosticGate.targetBundleIDEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else {
            return Self.failure("target bundle ID is empty")
        }
        guard let microphone = AVCaptureDevice.default(for: .audio), !microphone.uniqueID.isEmpty else {
            return Self.failure("no default microphone device is available")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            return Self.failure("shareable content unavailable")
        }
        guard let application = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return Self.failure("target application is not currently running")
        }
        guard application.processID > 0 else {
            return Self.failure("target application process provenance is unavailable")
        }
        guard let display = content.displays.first else {
            return Self.failure("no display is available")
        }

        let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
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
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphone.uniqueID

        let collector = MeetingSCKPairedDiagnosticCollector(environment: environment)
        let provenance = MeetingSCKPairedDiagnosticProvenance(
            scope: .selectedApplicationDisplay,
            applicationSelectionConfirmed: application.processID > 0
        )
        guard provenance.isValid else {
            return Self.failure("selected application provenance is invalid")
        }
        let output = MeetingSCKPairedAutorunOutput(collector: collector, provenance: provenance)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(
                output, type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "fluidvoice.c2.autorun.application", qos: .userInteractive)
            )
            try stream.addStreamOutput(
                output, type: .microphone,
                sampleHandlerQueue: DispatchQueue(label: "fluidvoice.c2.autorun.microphone", qos: .userInteractive)
            )
        } catch {
            await Self.stopCaptureBestEffort(stream)
            return Self.failure("paired ScreenCaptureKit outputs could not be attached")
        }

        do {
            try await Self.withTimeout(seconds: Self.operationTimeoutSeconds) {
                try await stream.startCapture()
            }
            try await Task.sleep(nanoseconds: UInt64(Self.captureDurationSeconds * 1_000_000_000))
            try Task.checkCancellation()
            try await Self.withTimeout(seconds: Self.operationTimeoutSeconds) {
                try await stream.stopCapture()
            }
        } catch is CancellationError {
            await Self.stopCaptureBestEffort(stream)
            return Self.failure("C2 autorun was cancelled")
        } catch {
            await Self.stopCaptureBestEffort(stream)
            return Self.failure("paired ScreenCaptureKit capture failed")
        }

        let report = collector.report()
        if let failure = Self.validationFailure(report) {
            return Self.failure(failure)
        }
        do {
            let reportObject = try JSONSerialization.jsonObject(with: report.jsonData())
            return Self.success(reportObject)
        } catch {
            return Self.failure("numeric C2 report serialization failed")
        }
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.completed else { return false }
            self.completed = true
            return true
        }
    }

    private static func validationFailure(_ report: MeetingSCKPairedDiagnosticReport) -> String? {
        guard report.enabled else { return "diagnostic gate was not enabled" }
        guard report.rejectedProvenanceCount == 0 else { return "provenance callbacks were rejected" }
        guard report.droppedAfterBoundCount == 0 else { return "collector bound dropped callbacks" }
        guard report.application.sampleCount > 0, report.microphone.sampleCount > 0 else {
            return "one or both paired outputs produced no samples"
        }
        guard report.application.validTimestampCount == report.application.sampleCount,
              report.microphone.validTimestampCount == report.microphone.sampleCount else {
            return "paired output timestamps were malformed"
        }
        guard report.application.firstPresentationSeconds?.isFinite == true,
              report.application.lastPresentationEndSeconds?.isFinite == true,
              report.microphone.firstPresentationSeconds?.isFinite == true,
              report.microphone.lastPresentationEndSeconds?.isFinite == true else {
            return "paired output timestamps were non-finite"
        }
        guard report.application.firstSampleRateHz?.isFinite == true,
              report.microphone.firstSampleRateHz?.isFinite == true,
              (report.application.firstSampleRateHz ?? 0) > 0,
              (report.microphone.firstSampleRateHz ?? 0) > 0,
              (report.application.firstChannelCount ?? 0) > 0,
              (report.microphone.firstChannelCount ?? 0) > 0 else {
            return "paired output formats were invalid"
        }
        guard report.acceptedSampleCount == report.application.sampleCount + report.microphone.sampleCount else {
            return "collector accepted count was inconsistent"
        }
        return nil
    }

    private static func success(_ report: Any) -> Outcome {
        let object: [String: Any] = ["exitStatus": 0, "report": report, "status": "success"]
        guard let line = Self.jsonLine(object) else {
            return Self.failure("numeric C2 report serialization failed")
        }
        return Outcome(exitStatus: 0, line: line)
    }

    private static func failure(_ reason: String) -> Outcome {
        let object: [String: Any] = ["exitStatus": 1, "reason": reason, "status": "failure"]
        return Outcome(exitStatus: 1, line: Self.jsonLine(object) ?? "{\"exitStatus\":1,\"status\":\"failure\"}")
    }

    private static func jsonLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private enum AutorunError: Error {
        case timeout
    }

    private static func stopCaptureBestEffort(_ stream: SCStream) async {
        try? await Self.withTimeout(seconds: Self.operationTimeoutSeconds) {
            try await stream.stopCapture()
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AutorunError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private final class MeetingSCKPairedAutorunOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let collector: MeetingSCKPairedDiagnosticCollector
    private let provenance: MeetingSCKPairedDiagnosticProvenance

    init(
        collector: MeetingSCKPairedDiagnosticCollector,
        provenance: MeetingSCKPairedDiagnosticProvenance
    ) {
        self.collector = collector
        self.provenance = provenance
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let output: MeetingSCKPairedOutput
        switch outputType {
        case .audio: output = .applicationAudio
        case .microphone: output = .microphone
        default: return
        }
        _ = self.collector.record(
            sampleBuffer: sampleBuffer, output: output, provenance: self.provenance
        )
    }
}

#endif
