#if DEBUG

@testable import FluidVoice_Debug
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest

/// One-shot, opt-in C2 topology probe. It is intentionally skipped in the normal suite and never
/// launches or identifies an application beyond the explicitly supplied target bundle ID.
final class MeetingSCKPairedHardwareTests: XCTestCase {
    private static let maximumDurationSeconds = 15.0
    private static let captureDurationSeconds = 5.0

    func testSelectedApplicationPairedSCKMetadataOnly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard MeetingSCKPairedDiagnosticGate.hardwareEnabled(environment: environment) else {
            throw XCTSkip(
                "Set FLUIDVOICE_C2_DIAGNOSTICS=1, FLUIDVOICE_C2_HARDWARE=1, and "
                    + "FLUIDVOICE_C2_TARGET_BUNDLE_ID to run the one-shot C2 probe."
            )
        }
        guard let bundleID = environment[MeetingSCKPairedDiagnosticGate.targetBundleIDEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else {
            throw XCTSkip("FLUIDVOICE_C2_TARGET_BUNDLE_ID is empty")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("microphone permission is not authorized")
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw XCTSkip("no default microphone is available")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw XCTSkip("ScreenCaptureKit shareable content unavailable: \(error.localizedDescription)")
        }
        guard let application = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw XCTSkip("target application is not currently running")
        }
        guard let display = content.displays.first else {
            throw XCTSkip("no display is available for the selected-application filter")
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
            throw XCTSkip("selected application process provenance is unavailable")
        }
        let output = C2HardwareMetadataOutput(collector: collector, provenance: provenance)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(
            label: "fluidvoice.c2.hardware.application", qos: .userInteractive
        ))
        try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: DispatchQueue(
            label: "fluidvoice.c2.hardware.microphone", qos: .userInteractive
        ))

        do {
            try await stream.startCapture()
            try await Task.sleep(nanoseconds: UInt64(Self.captureDurationSeconds * 1_000_000_000))
            try await stream.stopCapture()
        } catch {
            try? await stream.stopCapture()
            throw error
        }

        let report = collector.report()
        let data = try report.jsonData()
        print("[C2] sorted report JSON: \(String(decoding: data, as: UTF8.self))")
        XCTAssertTrue(report.enabled)
        XCTAssertEqual(report.provenance, provenance)
        XCTAssertEqual(report.rejectedProvenanceCount, 0)
        XCTAssertEqual(report.droppedAfterBoundCount, 0)
        XCTAssertGreaterThan(report.application.sampleCount, 0)
        XCTAssertGreaterThan(report.microphone.sampleCount, 0)
        XCTAssertEqual(report.acceptedSampleCount, report.application.sampleCount + report.microphone.sampleCount)
        XCTAssertEqual(report.application.validTimestampCount, report.application.sampleCount)
        XCTAssertEqual(report.microphone.validTimestampCount, report.microphone.sampleCount)
        XCTAssertTrue(report.application.firstPresentationSeconds?.isFinite == true)
        XCTAssertTrue(report.application.lastPresentationEndSeconds?.isFinite == true)
        XCTAssertTrue(report.microphone.firstPresentationSeconds?.isFinite == true)
        XCTAssertTrue(report.microphone.lastPresentationEndSeconds?.isFinite == true)
        XCTAssertTrue(report.application.firstSampleRateHz?.isFinite == true)
        XCTAssertTrue(report.microphone.firstSampleRateHz?.isFinite == true)
        XCTAssertGreaterThan(report.application.firstSampleRateHz ?? 0, 0)
        XCTAssertGreaterThan(report.microphone.firstSampleRateHz ?? 0, 0)
        XCTAssertGreaterThan(report.application.firstChannelCount ?? 0, 0)
        XCTAssertGreaterThan(report.microphone.firstChannelCount ?? 0, 0)
        XCTAssertLessThanOrEqual(Self.captureDurationSeconds, Self.maximumDurationSeconds)
        XCTAssertFalse(report.rawPCMRetained)
        XCTAssertFalse(report.transcriptRetained)
    }
}

private final class C2HardwareMetadataOutput: NSObject, SCStreamOutput, @unchecked Sendable {
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
