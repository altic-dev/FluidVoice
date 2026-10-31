import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest

private final class ProbeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { self.lock.withLock { self.time } }
    func advance() { self.lock.withLock { self.time = 121 } }
}

final class MeetingAudioComparisonProbeTests: XCTestCase {
    func testOptInReplaySavedMicrophoneThroughAECAndFallback() async throws {
        let request = (try? Data(contentsOf: URL(fileURLWithPath: "/tmp/fluidvoice-aec-replay-request.json")))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        guard let input = ProcessInfo.processInfo.environment["FLUIDVOICE_AEC_REPLAY_INPUT"] ?? request?["input"],
              let output = ProcessInfo.processInfo.environment["FLUIDVOICE_AEC_REPLAY_OUTPUT"] ?? request?["output"]
        else { throw XCTSkip("Set saved PCM input/output paths for a local diagnostic replay.") }
        for useFallback in [false, true] {
            let source = try AVAudioFile(forReading: URL(fileURLWithPath: input))
            XCTAssertEqual(source.processingFormat.sampleRate, 48_000)
            let directory = URL(fileURLWithPath: output).appendingPathComponent(useFallback ? "fallback" : "aec")
            let track = MeetingAudioTrack(
                id: UUID(),
                kind: .microphone,
                sourceIdentifier: "replay",
                sourceDisplayName: "Saved microphone",
                format: nil,
                timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
                health: .waiting,
                chunks: [],
                captureMethod: .screenCaptureKit,
                captureEras: [.init(method: .screenCaptureKit, deviceUID: nil, deviceName: nil, roleAtElection: .unknown, echoProtection: .unprotected, startSeconds: 0)]
            )
            let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: directory, chunkDuration: 60, eventHandler: { _ in })
            let gate = MeetingMicrophoneTranscriptGate(.unprotected)
            let counter = ReplaySampleCounter()
            let committer = MeetingAECOutputCommitter(
                writer: writer, transcriptGate: gate, liveAudioHandler: { _, sample in counter.add(CMSampleBufferGetNumSamples(sample)) }, terminalFailure: { _ in }
            )
            let processor: any MeetingAECProcessing
            if useFallback {
                processor = ReplayFailingAEC()
            } else {
                processor = try MeetingAECProcessor()
            }
            let pipeline = MeetingAECPipeline(processor: processor, committer: committer)
            let token = MeetingAECStreamToken(generation: 1, identity: 1)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 480))
            var offset: Int64 = 0
            var frames = 0
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: 480)
                let count = Int(buffer.frameLength)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                let samples = Array(UnsafeBufferPointer(start: channel, count: count))
                let pts = CMTime(value: offset, timescale: 48_000)
                let capture = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(samples: samples, presentationTime: pts))
                let render = try XCTUnwrap(MeetingAECPCMAdapter.synthesize(samples: [Float](repeating: 0, count: count), presentationTime: pts))
                pipeline.consumeRender(render, stream: token)
                pipeline.consumeCapture(capture, stream: token)
                offset += Int64(count)
                frames += 1
                if frames.isMultiple(of: 8) { _ = await writer.snapshot() }
            }
            await committer.waitForPendingCommits()
            pipeline.stop(boundary: gate.invalidate())
            await committer.waitForPendingCommits()
            let saved = await writer.stop()
            let chunk = try XCTUnwrap(saved.chunks.first)
            let file = try AVAudioFile(forReading: chunk.fileURL(relativeTo: directory))
            XCTAssertEqual(file.length, source.length, "filtering must not discard captured PCM")
            XCTAssertGreaterThan(counter.samples, 0)
            if useFallback { XCTAssertEqual(counter.samples, Int(source.length)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: directory.appendingPathComponent("replay-track.json"))
            print("AEC_REPLAY fallback=\(useFallback) recordedSamples=\(file.length) liveSamples=\(counter.samples) path=\(chunk.fileURL(relativeTo: directory).path)")
        }
    }

    func testRequestSurvivesWrongModeAndRetriesButExpires() throws {
        let name = "MeetingAudioComparisonProbeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(MeetingAudioComparisonProbe.requestExpiration(mode: .onlineCall, defaults: defaults, now: 100))
        XCTAssertNil(defaults.object(forKey: MeetingAudioComparisonProbe.requestExpirationKey))
        defaults.set(true, forKey: MeetingAudioComparisonProbe.nextRecordingKey)
        XCTAssertNil(MeetingAudioComparisonProbe.requestExpiration(mode: .inRoom, defaults: defaults, now: 100))
        let expiration = try XCTUnwrap(MeetingAudioComparisonProbe.requestExpiration(mode: .onlineCall, defaults: defaults, now: 101))
        XCTAssertEqual(expiration, 1900)
        XCTAssertEqual(MeetingAudioComparisonProbe.requestExpiration(mode: .onlineCall, defaults: defaults, now: 102), expiration)
        XCTAssertTrue(defaults.bool(forKey: MeetingAudioComparisonProbe.nextRecordingKey))
        MeetingAudioComparisonProbe.completeRequest(expiration: expiration - 1, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: MeetingAudioComparisonProbe.nextRecordingKey), "A stale probe cannot disarm a newer request")
        XCTAssertNil(MeetingAudioComparisonProbe.requestExpiration(mode: .onlineCall, defaults: defaults, now: expiration))
        XCTAssertNil(defaults.object(forKey: MeetingAudioComparisonProbe.nextRecordingKey))
        XCTAssertNil(defaults.object(forKey: MeetingAudioComparisonProbe.requestExpirationKey))
        defaults.set(true, forKey: MeetingAudioComparisonProbe.nextRecordingKey)
        let renewed = try XCTUnwrap(MeetingAudioComparisonProbe.requestExpiration(mode: .onlineCall, defaults: defaults, now: 2000))
        MeetingAudioComparisonProbe.completeRequest(expiration: renewed, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: MeetingAudioComparisonProbe.nextRecordingKey))
    }

    func testThreeStagesKeepIndependentPCMAndTimingOutsideNormalHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try MeetingAudioComparisonProbe(session: self.session(), directory: root)
        try probe.offer(self.sample(value: 0.25), stage: .browser)
        try probe.offer(self.sample(value: 0.5), stage: .microphoneInput)
        try probe.offer(self.sample(value: 0.1), stage: .microphoneOutput)
        try probe.offer(self.sample(value: 0.1), stage: .microphoneRecognizerInput)
        try probe.offer(self.sample(value: 0.25), stage: .browserRecognizerInput)
        probe.recordEvent("test-partial", text: "Known local test phrase")
        await probe.stop()
        await probe.stop()
        for (stage, value) in [(MeetingAudioComparisonProbe.Stage.browser, Float(0.25)), (.microphoneInput, 0.5), (.microphoneOutput, 0.1)] {
            let track = try self.track(stage, root: root)
            let chunk = try XCTUnwrap(track.chunks.first)
            XCTAssertEqual(chunk.captureAnalysisAsset?.frameCount, 480)
            XCTAssertEqual(chunk.presentationStart.seconds, 42, accuracy: 0.000_001)
            let url = root.appendingPathComponent(stage.rawValue).appendingPathComponent(chunk.relativeFilePath)
            let file = try AVAudioFile(forReading: url)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
            try file.read(into: pcm)
            let data = try XCTUnwrap(pcm.floatChannelData?[0])
            XCTAssertEqual(data[0], value, accuracy: 0.000_001)
            XCTAssertEqual(data[479], value, accuracy: 0.000_001)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session.json").path))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("comparison.json"))) as? [String: Any])
        XCTAssertEqual(report["hasAllStages"] as? Bool, true)
        XCTAssertEqual(report["completed"] as? Bool, true)
        var tracks: [String: MeetingAudioTrack] = [:]
        for stage in MeetingAudioComparisonProbe.Stage.allCases {
            tracks[stage.rawValue] = try self.track(stage, root: root)
        }
        XCTAssertFalse(MeetingAudioComparisonProbe.hasUsefulComparison(tracks), "A short attempt must leave diagnostics armed")
        let lines = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(event["step"] as? String, "test-partial")
        XCTAssertEqual(event["text"] as? String, "Known local test phrase")
    }

    func testFullComparisonCompletesRequestOnlyAfterReportIsSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = expectation(description: "Usable comparison saved")
        completed.assertForOverFulfill = true
        let probe = try MeetingAudioComparisonProbe(session: self.session(), directory: root, onUsefulComparison: {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("comparison.json").path))
            completed.fulfill()
        })
        for stage in MeetingAudioComparisonProbe.Stage.allCases {
            try probe.offer(self.sample(value: 0.1, frames: 1_440_000), stage: stage)
        }
        await probe.stop()
        await probe.stop()
        await fulfillment(of: [completed], timeout: 5)
    }

    func testProbeDeadlineAndStopDoNotDropOrChangeNormalRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ProbeTestClock()
        let probe = try MeetingAudioComparisonProbe(session: self.session(), directory: root.appendingPathComponent("probe"), maximumSeconds: 120, uptime: { clock.now() })
        XCTAssertTrue(probe.isRecordingDiagnostics)
        let normalTrack = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: self.session().timebase,
            health: .waiting,
            chunks: []
        )
        let writer = try MeetingAudioChunkWriter(
            track: normalTrack,
            sessionDirectory: root.appendingPathComponent("normal"),
            chunkDuration: 60,
            eventHandler: { _ in },
            diagnosticSampleObserver: { sample, epoch in probe.offer(sample, stage: .microphoneOutput, producerEpoch: epoch) }
        )
        XCTAssertTrue(try writer.enqueue(self.sample(value: 0.5)))
        _ = await writer.snapshot()
        clock.advance()
        XCTAssertFalse(probe.isRecordingDiagnostics)
        probe.recordEvent("expired-event", text: "Must not be retained")
        XCTAssertTrue(try writer.enqueue(self.sample(value: 0.5, pts: 42.01)))
        let normal = await writer.stop()
        await probe.stop()
        let diagnostic = try self.track(.microphoneOutput, root: root.appendingPathComponent("probe"))
        XCTAssertEqual(diagnostic.chunks.first?.captureAnalysisAsset?.frameCount, 480)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("probe/events.jsonl")).count, 0)
        XCTAssertEqual(normal.chunks.first?.captureAnalysisAsset?.frameCount, 960)
        XCTAssertEqual(normal.health.droppedSampleCount, 0)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("probe/comparison.json"))) as? [String: Any])
        XCTAssertEqual(report["hasAllStages"] as? Bool, false, "Missing raw input must never look like a valid comparison")
        try probe.offer(self.sample(value: 1), stage: .microphoneOutput)
        await probe.stop()
        XCTAssertEqual(try self.track(.microphoneOutput, root: root.appendingPathComponent("probe")).chunks.first?.captureAnalysisAsset?.frameCount, 480)
    }

    private func session() -> MeetingSession {
        MeetingSession(
            configuration: MeetingCaptureConfiguration(mode: .inRoom, title: "Probe", microphone: MeetingMicrophoneIdentity(captureDeviceID: "test", displayName: "Test")),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
    }

    private func sample(value: Float, pts: Double = 42, frames: AVAudioFrameCount = 480) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        try XCTUnwrap(pcm.floatChannelData?[0]).update(repeating: value, count: Int(frames))
        return try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(from: pcm, presentationTime: CMTime(seconds: pts, preferredTimescale: 48_000)))
    }

    private func track(_ stage: MeetingAudioComparisonProbe.Stage, root: URL) throws -> MeetingAudioTrack {
        let kind = stage == .browser || stage == .browserRecognizerInput ? "applicationAudio" : "microphone"
        let path = root.appendingPathComponent("\(stage.rawValue)/tracks/\(kind)/track.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingAudioTrack.self, from: Data(contentsOf: path))
    }
}

private final nonisolated class ReplayFailingAEC: MeetingAECProcessing, @unchecked Sendable {
    let upstreamRevision = MeetingAECConstants.provenance.upstreamRevision
    let configurationID = MeetingAECConstants.provenance.bridgeConfigurationID
    func process(render: [Float], capture: [Float]) throws -> (samples: [Float], statistics: MeetingAECBridgeStatistics) {
        throw MeetingAECFailure.bridgeProcessing
    }

    func reset() throws {}
}

private final nonisolated class ReplaySampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var samples: Int { self.lock.withLock { self.count } }
    func add(_ value: Int) { self.lock.withLock { self.count += value } }
}
