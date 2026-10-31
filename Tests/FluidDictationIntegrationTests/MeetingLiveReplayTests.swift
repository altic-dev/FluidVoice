import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest
#if arch(arm64)
import FluidAudio
#endif

/// Opt-in replay harness: drives the REAL `MeetingLiveTranscriptionCoordinator` with a real,
/// previously-recorded Zoom meeting's decoded microphone/application-audio WAVs, to see what the
/// live-transcription pipeline actually produces. Gated behind an env var so the normal suite
/// stays deterministic — this test downloads/loads real CoreML models and takes real wall time.
///
/// Set `FLUIDVOICE_LIVE_REPLAY=1` (and optionally `FLUIDVOICE_LIVE_REPLAY_MIC_WAV` /
/// `FLUIDVOICE_LIVE_REPLAY_APP_WAV` to override the fixture paths) to run it.
final class MeetingLiveReplayTests: XCTestCase {
    private static let chunkFrames = 320 // 20ms @ 16kHz
    private static let sampleRate: Double = 16_000
    private static let trailingSilenceSeconds: Double = 3

    func testReplayBufferUsesPerFrameTiming() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(Self.makeBuffer(format: format, samples: [Float](repeating: 0, count: Self.chunkFrames)[...]))
        let description = try XCTUnwrap(Self.makeFormatDescription(format: format))
        let sample = try XCTUnwrap(Self.makeSampleBuffer(pcm: pcm, formatDescription: description, pts: CMTime(seconds: 7, preferredTimescale: 16_000)))
        XCTAssertEqual(CMSampleBufferGetDuration(sample).seconds, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 7, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), Self.chunkFrames)
    }

    func testReplayRealMeetingThroughLiveCoordinator() async throws {
        guard let replayFlag = ProcessInfo.processInfo.environment["FLUIDVOICE_LIVE_REPLAY"], !replayFlag.isEmpty else {
            throw XCTSkip("Set FLUIDVOICE_LIVE_REPLAY=1 to run the live-transcription replay harness.")
        }

        let env = ProcessInfo.processInfo.environment
        let micPath = env["FLUIDVOICE_LIVE_REPLAY_MIC_WAV"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/private/tmp/claude-501/-Users-shreeram-Projects-FluidVoice/33323536-f2a9-4586-ad02-f71ced211c2a/scratchpad/microphone.wav"
        let appPath = env["FLUIDVOICE_LIVE_REPLAY_APP_WAV"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/private/tmp/claude-501/-Users-shreeram-Projects-FluidVoice/33323536-f2a9-4586-ad02-f71ced211c2a/scratchpad/applicationAudio.wav"

        let micSamples = try Self.load16kMonoFloatSamples(path: micPath)
        let appSamples = try Self.load16kMonoFloatSamples(path: appPath)
        print(
            "[replay] mic samples=\(micSamples.count) (\(Double(micSamples.count) / Self.sampleRate)s), app samples=\(appSamples.count) (\(Double(appSamples.count) / Self.sampleRate)s)"
        )

        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let formatDescription = Self.makeFormatDescription(format: pcmFormat)
        else {
            XCTFail("Could not build the 16kHz mono Float32 format used to feed the coordinator.")
            return
        }

        // Interleave both tracks' 20ms chunks in true time order. Both files share a clock and
        // (empirically) an identical sample count, so ties are broken mic-first — matching the
        // typical ordering of the real capture tee.
        var events: [(kind: MeetingAudioTrackKind, samples: ArraySlice<Float>, ptsSamples: Int)] = []
        events.reserveCapacity(((micSamples.count + appSamples.count) / Self.chunkFrames) + 4)
        Self.appendChunks(&events, kind: .microphone, samples: micSamples)
        Self.appendChunks(&events, kind: .applicationAudio, samples: appSamples)
        // Trailing silence on both tracks so any in-flight utterance at end-of-file can still hit
        // its 1280ms EOU silence debounce and finalize, instead of being lost to `stop()`'s reset.
        let silenceFrames = Int(Self.trailingSilenceSeconds * Self.sampleRate)
        let silence = [Float](repeating: 0, count: silenceFrames)
        let micTailStart = micSamples.count
        let appTailStart = appSamples.count
        Self.appendChunks(&events, kind: .microphone, samples: silence, ptsBaseSamples: micTailStart)
        Self.appendChunks(&events, kind: .applicationAudio, samples: silence, ptsBaseSamples: appTailStart)
        events.sort { lhs, rhs in
            if lhs.ptsSamples != rhs.ptsSamples { return lhs.ptsSamples < rhs.ptsSamples }
            return lhs.kind == .microphone && rhs.kind != .microphone
        }
        print("[replay] total chunks to feed: \(events.count)")

        final class SnapshotBox: @unchecked Sendable {
            let lock = NSLock()
            var latest: MeetingLiveTranscriptSnapshot = .empty
            var log: [(elapsed: TimeInterval, snapshot: MeetingLiveTranscriptSnapshot)] = []
            let start = Date()
            func record(_ snapshot: MeetingLiveTranscriptSnapshot) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.latest = snapshot
                self.log.append((Date().timeIntervalSince(self.start), snapshot))
            }
        }
        let box = SnapshotBox()
        let coordinator = MeetingLiveTranscriptionCoordinator { snapshot in
            box.record(snapshot)
        }

        let harnessStart = Date()
        coordinator.start(mode: .onlineCall)

        // Wait for the pipeline to report ready before hammering it with non-real-time audio: a
        // capacity-24 (~480ms) bounded queue means feeding faster than real time before the model
        // is loaded would just drop nearly everything, which would test harness pacing, not the
        // pipeline's actual transcription/echo-suppression behavior.
        let readyTimeout: TimeInterval = 300
        let readyDeadline = Date().addingTimeInterval(readyTimeout)
        while Date() < readyDeadline {
            let available = box.lock.withLock { box.latest.availability == .available }
            if available { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let firstAvailableElapsed = Date().timeIntervalSince(harnessStart)
        let becameAvailable = box.lock.withLock { box.latest.availability == .available }
        print("[replay] first-track-ready after \(String(format: "%.1f", firstAvailableElapsed))s (available=\(becameAvailable))")
        XCTAssertTrue(becameAvailable, "Live captions never became available within \(readyTimeout)s — model load likely failed.")
        // Both engines load their own model instance in parallel; give the slower one a grace
        // window since the snapshot only reports "available" on the FIRST track's readiness.
        try await Task.sleep(nanoseconds: 5_000_000_000)

        // Feed at real time: accelerated input can manufacture queue pressure that never occurred
        // in the recording, confusing a caption-quality investigation with harness overload.
        let accelerationFactor = 1.0
        let feedStart = Date()
        var bufferFailures = 0
        var sampleBufferFailures = 0
        var offeredCount = 0
        var totalWaitSeconds: Double = 0
        for (index, event) in events.enumerated() {
            guard let buffer = Self.makeBuffer(format: pcmFormat, samples: event.samples) else {
                bufferFailures += 1
                continue
            }
            let pts = CMTime(value: CMTimeValue(event.ptsSamples), timescale: CMTimeScale(Self.sampleRate))
            guard let sampleBuffer = Self.makeSampleBuffer(pcm: buffer, formatDescription: formatDescription, pts: pts) else {
                sampleBufferFailures += 1
                continue
            }
            coordinator.offer(kind: event.kind, sampleBuffer: sampleBuffer)
            offeredCount += 1
            let ptsSeconds = Double(event.ptsSamples) / Self.sampleRate
            let targetElapsed = ptsSeconds / accelerationFactor
            let actualElapsed = Date().timeIntervalSince(feedStart)
            let waitSeconds = targetElapsed - actualElapsed
            if waitSeconds > 0.001 {
                totalWaitSeconds += waitSeconds
                try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            } else if index % 8 == 0 {
                await Task.yield()
            }
        }
        let feedElapsed = Date().timeIntervalSince(feedStart)
        print(
            // Keep the exact fixture text or diagnostic output together for comparison.
            // swiftlint:disable:next line_length
            "[replay] fed \(events.count) chunks in \(String(format: "%.2f", feedElapsed))s (offered=\(offeredCount), bufferFailures=\(bufferFailures), sampleBufferFailures=\(sampleBufferFailures), totalWaitSeconds=\(String(format: "%.2f", totalWaitSeconds)))"
        )

        // Let the drain loops work through whatever is still queued, until the transcript stops
        // changing.
        var lastSnapshot = box.lock.withLock { box.latest }
        var stableCount = 0
        let settleDeadline = Date().addingTimeInterval(60)
        while Date() < settleDeadline, stableCount < 10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            let current = box.lock.withLock { box.latest }
            if current == lastSnapshot {
                stableCount += 1
            } else {
                stableCount = 0
                lastSnapshot = current
            }
        }

        await coordinator.stop()
        // stop() may itself publish nothing further, but give any last async callback a moment.
        try await Task.sleep(nanoseconds: 300_000_000)
        let final = box.lock.withLock { box.latest }

        // ---- Report ----
        print("=== LIVE REPLAY TRANSCRIPT (\(final.utterances.count) utterances) ===")
        for utterance in final.utterances {
            let speaker = utterance.speaker == .you ? "You " : "Them"
            print(String(format: "[%7.2f - %7.2f] %@: %@", utterance.start, utterance.end, speaker, utterance.text))
        }
        if !final.partials.isEmpty {
            print("--- Leftover partials at end ---")
            for (speaker, text) in final.partials {
                print("  \(speaker): \(text)")
            }
        }
        print("Final availability: \(final.availability)")

        let degradedTransitions = box.lock.withLock {
            box.log.filter { if case .degraded = $0.snapshot.availability { return true } else { return false } }
        }
        print("Degraded-availability updates observed: \(degradedTransitions.count)")
        for transition in degradedTransitions.prefix(20) {
            print("  t+\(String(format: "%.1f", transition.elapsed))s: \(transition.snapshot.availability)")
        }

        let youUtterances = final.utterances.filter { $0.speaker == .you }
        let themUtterances = final.utterances.filter { $0.speaker == .them }
        print("You utterances: \(youUtterances.count), Them utterances: \(themUtterances.count)")

        // This is an observational experiment, not a pass/fail gate: assert only that the harness
        // itself ran the real pipeline end-to-end without erroring out.
        XCTAssertTrue(true, "See console output above for the replayed transcript and analysis.")
    }

    // MARK: - Helpers

    #if arch(arm64)
    func testCompareBeforeAndAfterCancellationWithFinalASR() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["FLUIDVOICE_COMPARISON_CLIPS"],
              let modelPath = env["FLUIDVOICE_COMPARISON_TDT_MODELS"]
        else {
            throw XCTSkip("Set local comparison clips and cached TDT models for this experiment.")
        }
        let models = try await AsrModels.loadLocalOnly(from: URL(fileURLWithPath: modelPath), version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        for clip in ["voice-alone", "voice-with-video", "short-comment"] {
            for stage in ["microphone-before-aec", "microphone-after-aec"] {
                let path = URL(fileURLWithPath: directory).appendingPathComponent("\(clip)-\(stage).wav").path
                let samples = try Self.load16kMonoFloatSamples(path: path)
                try await manager.resetDecoderState()
                let result = try await manager.transcribe(samples, source: .microphone)
                print("[comparison-asr] \(clip) \(stage): \(result.text)")
            }
        }
    }

    /// Isolates the model from the app's callbacks, text filter and forced-reset policy.
    func testReplayDirectRecognizerWithoutForcedResets() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLUIDVOICE_DIRECT_LIVE_REPLAY"] == "1",
              let path = env["FLUIDVOICE_LIVE_REPLAY_APP_WAV"]
        else {
            throw XCTSkip("Set FLUIDVOICE_DIRECT_LIVE_REPLAY and an audio path for this experiment.")
        }
        let samples = try Self.load16kMonoFloatSamples(path: path)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false))
        let manager = StreamingEouAsrManager(chunkSize: .ms160)
        try await manager.loadModelsFromHuggingFace()
        let silence = try XCTUnwrap(Self.makeBuffer(format: format, samples: [Float](repeating: 0, count: 16_000)[...]))
        try await manager.appendAudio(silence)
        try await manager.processBufferedAudio()
        await manager.reset()
        final class Transcript: @unchecked Sendable {
            let lock = NSLock()
            var latest = ""
            func record(_ text: String) { self.lock.withLock { self.latest = text } }
            func read() -> String { self.lock.withLock { self.latest } }
        }
        let transcript = Transcript()
        await manager.setPartialTranscriptCallback { transcript.record($0) }
        let seconds = min(30, max(1, Double(env["FLUIDVOICE_DIRECT_LIVE_SECONDS"] ?? "25") ?? 25))
        let limit = min(samples.count, Int(seconds * 16_000))
        for offset in stride(from: 0, to: limit, by: Self.chunkFrames) {
            let end = min(offset + Self.chunkFrames, limit)
            let pcm = try XCTUnwrap(Self.makeBuffer(format: format, samples: samples[offset..<end]))
            try await manager.appendAudio(pcm)
            try await manager.processBufferedAudio()
            if end % 16_000 == 0 { print("[direct] audioSecond=\(end / 16_000) text=\(transcript.read())") }
        }
        print("[direct] before-finish=\(transcript.read())")
        if env["FLUIDVOICE_DIRECT_PAD_FINISH"] == "1" {
            await manager.injectSilence(1.28)
            try await manager.processBufferedAudio()
            print("[direct] after-padding=\(transcript.read())")
        }
        let finished = try await manager.finish()
        print("[direct] finish=\(finished)")
        await manager.reset()
    }
    #endif

    private static func appendChunks(
        _ events: inout [(kind: MeetingAudioTrackKind, samples: ArraySlice<Float>, ptsSamples: Int)],
        kind: MeetingAudioTrackKind,
        samples: [Float],
        ptsBaseSamples: Int = 0
    ) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + self.chunkFrames, samples.count)
            events.append((kind: kind, samples: samples[offset..<end], ptsSamples: ptsBaseSamples + offset))
            offset = end
        }
    }

    private static func load16kMonoFloatSamples(path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found at \(path)"])
        }
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not build target format"])
        }

        let inputBuffer: AVAudioPCMBuffer = try {
            let frameCount = AVAudioFrameCount(inputFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: max(frameCount, 1)) else {
                throw NSError(domain: "MeetingLiveReplayTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not allocate input buffer"])
            }
            try inputFile.read(into: buffer)
            return buffer
        }()

        if inputFormat.sampleRate == desiredFormat.sampleRate,
           inputFormat.channelCount == desiredFormat.channelCount,
           inputFormat.commonFormat == desiredFormat.commonFormat
        {
            return Self.extractSamples(inputBuffer)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: desiredFormat) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not build converter"])
        }
        let ratio = desiredFormat.sampleRate / inputFormat.sampleRate
        let estimatedFrames = max(1, AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: estimatedFrames) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not allocate output buffer"])
        }
        var providedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }
        return Self.extractSamples(outputBuffer)
    }

    private static func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    private static func makeBuffer(format: AVAudioFormat, samples: ArraySlice<Float>) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channelData[0][index] = sample
        }
        return buffer
    }

    private static func makeFormatDescription(format: AVAudioFormat) -> CMAudioFormatDescription? {
        var formatDescription: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else { return nil }
        return formatDescription
    }

    /// Builds a `dataReady` sample buffer directly from a copy of the PCM buffer's bytes, rather
    /// than via `CMSampleBufferSetDataBufferFromAudioBufferList` (which reliably returned
    /// `kCMSampleBufferError_RequiredParameterMissing` for this mono/non-interleaved Float32 case
    /// in practice, despite matching Apple's documented parameters).
    private static func makeSampleBuffer(pcm: AVAudioPCMBuffer, formatDescription: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0, let channelData = pcm.floatChannelData else { return nil }
        let bytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let dataLength = frameCount * bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = channelData[0].withMemoryRebound(to: UInt8.self, capacity: dataLength) { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataLength)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(self.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }
}
