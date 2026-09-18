@testable import FluidVoice_Debug
import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation
import XCTest

private final class MeetingPCMFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// P1a's sink fixtures intentionally use real ready CMSampleBuffers.  These tests stay in the
/// integration target because the sink is an internal harness type, not a package product.
final class MeetingAudioChunkSinkTests: XCTestCase {
    func testWriterAcceptsEquivalentRawMonoLayoutsWithoutRotatingOrFailing() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(), kind: .applicationAudio, sourceIdentifier: "test", sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        let tags: [UInt32?] = [nil, kAudioChannelLayoutTag_Mono, nil, kAudioChannelLayoutTag_DiscreteInOrder | 1]
        for (index, tag) in tags.enumerated() {
            writer.enqueue(try self.makeRawSampleBuffer(channelCount: 1, layoutTag: tag, frameCount: 480, pts: Double(index) * 0.01))
        }
        let result = await writer.stop()
        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        XCTAssertEqual(chunk.captureAnalysisAsset?.frameCount, 1_920)
        XCTAssertEqual(failures.value(), 0)
        XCTAssertEqual(chunk.discontinuities, [])
        let file = try AVAudioFile(forReading: root.appendingPathComponent(chunk.relativeFilePath), commonFormat: .pcmFormatFloat32, interleaved: true)
        XCTAssertEqual(file.length, 1_920)
    }

    func testWriterRotatesExactlyOnceForGenuineMonoToStereoChange() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(), kind: .applicationAudio, sourceIdentifier: "test", sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        writer.enqueue(try self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 0))
        writer.enqueue(try self.makeRawSampleBuffer(channelCount: 2, layoutTag: kAudioChannelLayoutTag_Stereo, frameCount: 480, pts: 0.01))
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
        let mono = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true,
            channelLayout: try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono))
        ))
        let discrete0 = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true,
            channelLayout: try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 1))
        ))
        let stereoNil = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let stereo = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true,
            channelLayout: try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        ))

        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: monoNil), try MeetingPCMFormatContract(audioFormat: mono))
        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: mono), try MeetingPCMFormatContract(audioFormat: discrete0))
        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: stereoNil), try MeetingPCMFormatContract(audioFormat: stereo))
        XCTAssertNotEqual(try MeetingPCMFormatContract(audioFormat: monoNil), try MeetingPCMFormatContract(audioFormat: stereoNil))
        XCTAssertThrowsError(try MeetingPCMFormatContract(audioFormat: try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))))
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
            let read = Array(UnsafeBufferPointer(start: readBuffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self), count: samples.count))
            XCTAssertEqual(read, samples)
            let digest = SHA256.hash(data: try Data(contentsOf: finalURL)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(finalization.sha256, digest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tracks/application/000001.partial.caf").path))
            let mode = (try FileManager.default.attributesOfItem(atPath: finalURL.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, Int(0o600))
            let parentMode = (try FileManager.default.attributesOfItem(atPath: finalURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
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

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoice-P1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return url
    }

    private func makeRawSampleBuffer(channelCount: Int, layoutTag: UInt32?, frameCount: Int, pts: Double) throws -> CMSampleBuffer {
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let layout = layoutTag.flatMap { AVAudioChannelLayout(layoutTag: $0) }
        let layoutStatus: OSStatus
        if let layout, let layoutData = MeetingPCMFormatContract.layoutData(layout) {
            layoutStatus = layoutData.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                    layoutSize: layoutData.count, layout: bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            }
        } else {
            layoutStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        }
        XCTAssertEqual(layoutStatus, noErr)
        let values = Array(repeating: Float(0.25), count: frameCount * channelCount)
        let bytes = values.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), noErr)
        let blockBuffer = try XCTUnwrap(block)
        XCTAssertEqual(bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes.count) }, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: try XCTUnwrap(description), sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func makeSampleBuffer(format: AVAudioFormat, interleavedSamples: [Float], frameCount: Int, pts: Double) throws -> CMSampleBuffer {
        let bytes = interleavedSamples.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw NSError(domain: "P1a", code: Int(status)) }
        status = bytes.withUnsafeBytes { ptr in
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
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format.formatDescription, sampleCount: frameCount,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                           sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw NSError(domain: "P1a", code: Int(status)) }
        return sampleBuffer
    }
}
