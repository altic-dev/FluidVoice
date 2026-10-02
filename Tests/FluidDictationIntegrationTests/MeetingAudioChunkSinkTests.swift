import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

private final class MeetingPCMFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { self.lock.lock(); self.count += 1; self.lock.unlock() }
    func value() -> Int { self.lock.lock(); defer { lock.unlock() }; return self.count }
}

private final class MeetingWriterEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeetingCaptureEvent] = []

    func record(_ event: MeetingCaptureEvent) {
        self.lock.withLock { self.events.append(event) }
    }

    func snapshot() -> [MeetingCaptureEvent] {
        self.lock.withLock { self.events }
    }
}

/// P1a's sink fixtures intentionally use real ready CMSampleBuffers.  These tests stay in the
/// integration target because the sink is an internal harness type, not a package product.
final class MeetingAudioChunkSinkTests: XCTestCase {
    func testUnsupportedMicrophoneBuffersReportOneFailureAndRecover() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        let events = MeetingWriterEventRecorder()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) {
            events.record($0)
        }
        let integerFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let integerBytes = [Int16](repeating: 100, count: 480).withUnsafeBytes { Data($0) }
        for index in 0..<1_000 {
            let sample = try self.makeSampleBuffer(format: integerFormat, bytes: integerBytes, frameCount: 480, pts: Double(index) * 0.01)
            XCTAssertTrue(writer.enqueue(sample))
            // Drain each callback to test format rejection, rather than producer backpressure.
            _ = await writer.snapshot()
        }
        let rejected = await writer.snapshot()
        XCTAssertEqual(rejected.health.status, .degraded)
        XCTAssertTrue(rejected.chunks.isEmpty)
        XCTAssertEqual(rejected.health.detail, "Unsupported PCM format: native Float32 LPCM required.")
        XCTAssertEqual(events.snapshot().count, 2, "One interruption and one degraded health update for the whole failure episode")
        if case let .trackHealth(trackID, health) = events.snapshot().last {
            XCTAssertEqual(trackID, track.id)
            XCTAssertEqual(health.status, .degraded)
        } else {
            XCTFail("The coordinator must receive degraded track health")
        }

        writer.enqueue(try self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 10))
        let recovered = await writer.snapshot()
        XCTAssertEqual(recovered.health.status, .healthy)
        XCTAssertNil(recovered.health.detail)
        if case let .trackHealth(_, health) = events.snapshot().last {
            XCTAssertEqual(health.status, .healthy)
        } else {
            XCTFail("Recovery must publish healthy track status immediately")
        }

        // The first rejection retires the active sink; later ones fail before a sink exists.
        // Both paths belong to one new failure episode, even though their error strings differ.
        for index in 1_001..<1_101 {
            writer.enqueue(try self.makeSampleBuffer(format: integerFormat, bytes: integerBytes, frameCount: 480, pts: Double(index) * 0.01))
            _ = await writer.snapshot()
        }
        let failures = events.snapshot().filter {
            if case .interrupted(.writerFailure, _, _) = $0 { return true }
            return false
        }
        XCTAssertEqual(failures.count, 2, "Recovery re-arms reporting exactly once")
        writer.enqueue(try self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 11.01))
        let stopped = await writer.stop()
        XCTAssertEqual(stopped.chunks.filter { $0.finalizationState == .finalized }.count, 1)
    }

    func testLayoutlessThreeChannelMicrophoneResolvesCopiesConvertsAndWrites() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try self.makeRawSampleBuffer(channelCount: 3, layoutTag: nil, frameCount: 512, pts: 1.25)
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertNil(MeetingPCMFormatContract.layoutData(description))

        let format = try MeetingPCMFormatResolver.resolve(description)
        XCTAssertEqual(format.channelCount, 3)
        XCTAssertNotNil(format.channelLayout)

        let copied = try XCTUnwrap(MeetingLiveSampleCopy.copy(sample))
        XCTAssertEqual(copied.buffer.format.channelCount, 1)
        XCTAssertEqual(copied.buffer.frameLength, 512)
        XCTAssertEqual(copied.pts.seconds, 1.25, accuracy: 0.000_001)
        let copiedSamples = try Array(UnsafeBufferPointer(
            start: XCTUnwrap(copied.buffer.floatChannelData?[0]),
            count: Int(copied.buffer.frameLength)
        ))
        XCTAssertTrue(copiedSamples.allSatisfy { abs($0 - 0.25) < 0.000_001 })

        let mono = try self.convertToMono(copied.buffer)
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.format.sampleRate, 16_000)
        XCTAssertGreaterThan(mono.frameLength, 0)

        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(
            track: track, sessionDirectory: root, chunkDuration: 60
        ) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        writer.enqueue(sample)
        let result = await writer.stop()
        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        XCTAssertEqual(chunk.captureAnalysisAsset?.channelCount, 3)
        XCTAssertEqual(chunk.captureAnalysisAsset?.frameCount, 512)
        XCTAssertEqual(failures.value(), 0)
    }

    func testWriterAcceptsEquivalentRawMonoLayoutsWithoutRotatingOrFailing() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .applicationAudio,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        let tags: [UInt32?] = [nil, kAudioChannelLayoutTag_Mono, nil, kAudioChannelLayoutTag_DiscreteInOrder | 1]
        for (index, tag) in tags.enumerated() {
            try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: tag, frameCount: 480, pts: Double(index) * 0.01))
        }
        let result = await writer.stop()
        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        XCTAssertEqual(chunk.captureAnalysisAsset?.frameCount, 1920)
        XCTAssertEqual(failures.value(), 0)
        XCTAssertEqual(chunk.discontinuities, [])
        let file = try AVAudioFile(forReading: root.appendingPathComponent(chunk.relativeFilePath), commonFormat: .pcmFormatFloat32, interleaved: true)
        XCTAssertEqual(file.length, 1920)
    }

    func testWriterRotatesExactlyOnceForGenuineMonoToStereoChange() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .applicationAudio,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 0))
        try writer.enqueue(self.makeRawSampleBuffer(channelCount: 2, layoutTag: kAudioChannelLayoutTag_Stereo, frameCount: 480, pts: 0.01))
        let result = await writer.stop()
        XCTAssertEqual(result.chunks.count, 2)
        XCTAssertEqual(result.chunks.map { $0.captureAnalysisAsset?.frameCount }, [480, 480])
        XCTAssertEqual(result.chunks.map(\.finalizationState), [.finalized, .finalized])
        XCTAssertEqual(failures.value(), 0)
    }

    func testSinkFormatMismatchErrorUsesNormalizedExpectedAndActualContracts() throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        try sink.begin(relativeFilePath: "mismatch.caf", format: mono)
        XCTAssertThrowsError(try sink.append(self.makeRawSampleBuffer(channelCount: 2, layoutTag: kAudioChannelLayoutTag_Stereo, frameCount: 2, pts: 0))) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(message.contains("lpcm-f32 rate=48000.0 channels=1 layout=mono"), message)
            XCTAssertTrue(message.contains("lpcm-f32 rate=48000.0 channels=2 layout=stereo"), message)
        }
        sink.cancel()
    }

    func testPCMFormatContractCanonicalizesEquivalentMonoAndStereoLayouts() throws {
        let monoNil = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let mono = try XCTUnwrap(try AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono))
        ))
        let discrete0 = try XCTUnwrap(try AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 1))
        ))
        let stereoNil = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let stereo = try XCTUnwrap(try AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        ))

        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: monoNil), try MeetingPCMFormatContract(audioFormat: mono))
        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: mono), try MeetingPCMFormatContract(audioFormat: discrete0))
        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: stereoNil), try MeetingPCMFormatContract(audioFormat: stereo))
        XCTAssertNotEqual(try MeetingPCMFormatContract(audioFormat: monoNil), try MeetingPCMFormatContract(audioFormat: stereoNil))
        XCTAssertThrowsError(try MeetingPCMFormatContract(audioFormat: XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))))
    }

    func testMonoAndStereoPreserveFramesPTSAndPublishCAF() async throws {
        for channels in [1, 2] {
            let root = try self.makeDirectory()
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true))
            let samples: [Float] = (0..<(17 * channels)).map { Float($0 + 1) / 100 }
            let buffer = try self.makeSampleBuffer(format: format, interleavedSamples: samples, frameCount: 17, pts: 2.25)
            let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
            try sink.begin(relativeFilePath: "tracks/application/000001.caf", format: format)
            let receipt = try sink.append(buffer)
            XCTAssertEqual(receipt.framesAccepted, 17)
            XCTAssertEqual(receipt.framesWritten, 17)
            XCTAssertEqual(receipt.presentationStart.seconds, 2.25, accuracy: 0.000_001)
            XCTAssertEqual(receipt.presentationDuration.seconds, 17.0 / 48_000.0, accuracy: 0.000_001)
            let result = sink.finalize()
            let finalization = try result.get()
            XCTAssertEqual(finalization.frameCount, 17)
            XCTAssertEqual(finalization.channelCount, channels)
            XCTAssertEqual(finalization.sampleRate, 48_000)
            let finalURL = root.appendingPathComponent("tracks/application/000001.caf")
            let file = try AVAudioFile(
                forReading: finalURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            let readBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 17))
            try file.read(into: readBuffer)
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            let read = Array(UnsafeBufferPointer(start: readBuffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self), count: samples.count))
            XCTAssertEqual(read, samples)
            let digest = try SHA256.hash(data: Data(contentsOf: finalURL)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(finalization.sha256, digest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tracks/application/000001.partial.caf").path))
            let mode = try (FileManager.default.attributesOfItem(atPath: finalURL.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, Int(0o600))
            let parentMode = try (FileManager.default.attributesOfItem(atPath: finalURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(parentMode, Int(0o700))
        }
    }

    func testRejectsFormatDriftAndNonFiniteWithoutPublishing() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let otherFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "chunk.caf", format: format)
        XCTAssertThrowsError(try sink.append(self.makeSampleBuffer(format: otherFormat, interleavedSamples: [0, 1], frameCount: 2, pts: 0)))
        // A format mismatch poisons the sink and closes its file. Subsequent buffers must not be
        // retried against that instance; the writer retires the chunk and opens a fresh one.
        XCTAssertThrowsError(try sink.append(self.makeSampleBuffer(format: format, interleavedSamples: [0], frameCount: 1, pts: .nan))) { error in
            XCTAssertEqual(error as? MeetingPCMSinkError, .alreadyFinalizedOrCancelled)
        }
        sink.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("chunk.caf").path))
    }

    func testConfinementExistingFinalAndStalePartialAreFailClosed() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        XCTAssertThrowsError(try sink.begin(relativeFilePath: "../escape.caf", format: format))
        let partial = root.appendingPathComponent("chunk.partial.caf")
        try Data([1, 2, 3]).write(to: partial)
        try sink.begin(relativeFilePath: "chunk.caf", format: format)
        _ = try sink.append(self.makeSampleBuffer(
            format: format,
            interleavedSamples: [0.25],
            frameCount: 1,
            pts: 0
        ))
        let staleFinalization = sink.finalize()
        _ = try staleFinalization.get()
        XCTAssertEqual(try Data(contentsOf: partial), Data([1, 2, 3]), "stale partial must not be promoted or removed")
        try FileManager.default.removeItem(at: root.appendingPathComponent("chunk.caf"))
        try Data([1]).write(to: root.appendingPathComponent("chunk.caf"))
        let existingFinalSink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        XCTAssertThrowsError(try existingFinalSink.begin(relativeFilePath: "chunk.caf", format: format)) { error in
            XCTAssertEqual(error as? MeetingPCMSinkError, .finalPathAlreadyExists("chunk.caf"))
        }
        let outside = root.deletingLastPathComponent().appendingPathComponent("FluidVoice-P1a-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try MeetingAudioFilePCMChunkSink(sessionDirectory: root).begin(relativeFilePath: "linked/escape.caf", format: format)) { error in
            XCTAssertEqual(error as? MeetingPCMSinkError, .symlinkComponentRejected(link.path))
        }
    }

    func testCancelAndFailedFinalizeNeverCreateFinal() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "cancel.caf", format: format)
        sink.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel.caf").path))
        let failed = sink.finalize()
        XCTAssertEqual(failed, .failure(.alreadyFinalizedOrCancelled))
    }

    func testNonInterleavedStereoIsPackedInChannelOrderAndCountsPackets() async throws {
        let root = try self.makeDirectory()
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        ))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "noninterleaved.caf", format: format)
        // Planar input: left frames followed by right frames. The file is interleaved L/R.
        let first = try self.makeSampleBuffer(format: format, interleavedSamples: [0.1, 0.2, 0.3, 0.4, 1.1, 1.2, 1.3, 1.4], frameCount: 4, pts: 0)
        let second = try self.makeSampleBuffer(format: format, interleavedSamples: [0.5, 0.6, 1.5, 1.6], frameCount: 2, pts: 4.0 / 48_000.0)
        XCTAssertEqual(try sink.append(first).framesWritten, 4)
        XCTAssertEqual(try sink.append(second).framesWritten, 2)
        let finalization = try sink.finalize().get()
        XCTAssertEqual(finalization.frameCount, 6)
        let file = try AVAudioFile(forReading: root.appendingPathComponent("noninterleaved.caf"), commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 6))
        try file.read(into: buffer)
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let values = Array(UnsafeBufferPointer(start: buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self), count: 12))
        XCTAssertEqual(values, [0.1, 1.1, 0.2, 1.2, 0.3, 1.3, 0.4, 1.4, 0.5, 1.5, 0.6, 1.6])
    }

    func testFinalizeWithoutFramesFailsAndCleansOwnedPartial() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "empty.caf", format: format)

        let result = sink.finalize()

        guard case let .failure(.finalizationVerificationFailed(detail)) = result else {
            return XCTFail("Expected an empty-CAF verification failure, got \(result)")
        }
        XCTAssertEqual(detail, "CAF contains no written frames")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty.caf").path))
        let partials = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".partial.") }
        XCTAssertTrue(partials.isEmpty)
    }

    private func convertToMono(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: source.format, to: monoFormat))
        let capacity = AVAudioFrameCount(
            (Double(source.frameLength) * monoFormat.sampleRate / source.format.sampleRate).rounded(.up)
        ) + 16
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity))
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
        XCTAssertNotEqual(status, .error)
        return output
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoice-P1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return url
    }

    private func makeRawSampleBuffer(channelCount: Int, layoutTag: UInt32?, frameCount: Int, pts: Double) throws -> CMSampleBuffer {
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let layout = layoutTag.flatMap { AVAudioChannelLayout(layoutTag: $0) }
        let layoutStatus: OSStatus
        if let layout, let layoutData = MeetingPCMFormatContract.layoutData(layout) {
            layoutStatus = layoutData.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: layoutData.count,
                    // Fixed test fixture: missing required audio storage or evidence is a setup failure.
                    // swiftlint:disable:next force_unwrapping
                    layout: bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        } else {
            layoutStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        XCTAssertEqual(layoutStatus, noErr)
        let values = Array(repeating: Float(0.25), count: frameCount * channelCount)
        let bytes = values.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ), noErr)
        let blockBuffer = try XCTUnwrap(block)
        XCTAssertEqual(
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes.count) },
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            try CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: XCTUnwrap(description),
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sample
            ),
            noErr
        )
        return try XCTUnwrap(sample)
    }

    private func makeSampleBuffer(format: AVAudioFormat, interleavedSamples: [Float], frameCount: Int, pts: Double) throws -> CMSampleBuffer {
        try self.makeSampleBuffer(
            format: format, bytes: interleavedSamples.withUnsafeBytes { Data($0) }, frameCount: frameCount, pts: pts
        )
    }

    private func makeSampleBuffer(format: AVAudioFormat, bytes: Data, frameCount: Int, pts: Double) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw NSError(domain: "P1a", code: Int(status)) }
        status = bytes.withUnsafeBytes { ptr in
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw NSError(domain: "P1a", code: Int(status)) }
        let presentationTimeStamp = pts.isFinite
            ? CMTime(seconds: pts, preferredTimescale: 1_000_000)
            : .invalid
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format.formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw NSError(domain: "P1a", code: Int(status)) }
        return sampleBuffer
    }
}
