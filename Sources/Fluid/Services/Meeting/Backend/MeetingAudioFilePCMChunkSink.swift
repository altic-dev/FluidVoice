import AudioToolbox
@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation

/// PCM capture sink. The caller owns serialization on a non-real-time queue. The CAF payload is
/// canonical interleaved native-rate Float32 LPCM; non-interleaved input is only packed at the
/// sink boundary (there is no resampling, channel clamp, or quantization).
///
/// Path validation is lexical plus lstat-based.  A descriptor-relative `openat`/`renameat` walk
/// is intentionally deferred: a hostile concurrent rename can still create a path TOCTOU window,
/// so this harness must not be described as a production security boundary.  The crash harness
/// that kills a subprocess between each durability point is also a follow-up, not production-ready
/// recovery behavior.
final nonisolated class MeetingAudioFilePCMChunkSink: MeetingAudioChunkSink, @unchecked Sendable {
    private enum State { case idle, open, finalized, cancelled }
    private struct Format {
        let rate: Double
        let channels: UInt32
        let layout: Data?
        let contract: MeetingPCMFormatContract
    }
    private struct Paths { let final: URL; let partial: URL }
    private struct Identity { let dev: dev_t; let ino: ino_t; let size: off_t }
    private let sessionDirectory: URL
    private var state: State = .idle
    private var audioFile: AudioFileID?
    private var paths: Paths?
    private var format: Format?
    private var fileASBD: AudioStreamBasicDescription?
    private var writtenPackets: Int64 = 0
    private var poisoned = false

    var partialRelativeFilePath: String? {
        guard let partial = paths?.partial else { return nil }
        let root = sessionDirectory.path.hasSuffix("/") ? sessionDirectory.path : sessionDirectory.path + "/"
        guard partial.path.hasPrefix(root) else { return nil }
        return String(partial.path.dropFirst(root.count))
    }

    init(sessionDirectory: URL) { self.sessionDirectory = sessionDirectory.standardizedFileURL }

    deinit { if let audioFile { AudioFileClose(audioFile) } }

    func begin(relativeFilePath: String, format: AVAudioFormat) throws {
        let contract: MeetingPCMFormatContract
        do { contract = try MeetingPCMFormatContract(audioFormat: format) }
        catch { throw MeetingPCMSinkError.unsupportedClientFormat(error.localizedDescription) }
        try begin(relativeFilePath: relativeFilePath, format: format, contract: contract)
    }

    func begin(relativeFilePath: String, format: AVAudioFormat, contract: MeetingPCMFormatContract) throws {
        guard state == .idle else { throw MeetingPCMSinkError.alreadyBegun }
        let inputASBD = format.streamDescription.pointee
        let derivedContract: MeetingPCMFormatContract
        do { derivedContract = try MeetingPCMFormatContract(audioFormat: format) }
        catch { throw MeetingPCMSinkError.unsupportedClientFormat(error.localizedDescription) }
        guard derivedContract == contract else {
            throw MeetingPCMSinkError.formatMismatch(expected: contract.description, actual: derivedContract.description)
        }
        let layout = Self.layoutData(format.channelLayout)
        let paths = try resolvePaths(relativeFilePath)
        var asbd = try Self.canonicalASBD(rate: inputASBD.mSampleRate, channels: inputASBD.mChannelsPerFrame)
        var file: AudioFileID?
        let status = AudioFileCreateWithURL(paths.partial as CFURL, kAudioFileCAFType, &asbd, [], &file)
        guard status == noErr, let file else { throw MeetingPCMSinkError.writeFailed(status) }
        guard chmod(paths.partial.path, mode_t(0o600)) == 0 else {
            AudioFileClose(file); try? FileManager.default.removeItem(at: paths.partial)
            throw MeetingPCMSinkError.underlyingFileError("could not set partial permissions")
        }
        if let layout {
            let setStatus = layout.withUnsafeBytes {
                AudioFileSetProperty(file, kAudioFilePropertyChannelLayout, UInt32($0.count), $0.baseAddress!)
            }
            guard setStatus == noErr else {
                AudioFileClose(file); try? FileManager.default.removeItem(at: paths.partial)
                throw MeetingPCMSinkError.writeFailed(setStatus)
            }
        }
        self.audioFile = file
        self.paths = paths
        self.format = Format(rate: inputASBD.mSampleRate, channels: inputASBD.mChannelsPerFrame, layout: layout, contract: contract)
        self.fileASBD = asbd
        self.writtenPackets = 0
        self.poisoned = false
        self.state = .open
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws -> MeetingPCMAppendReceipt {
        guard state == .open, let file = audioFile, let format, let expectedASBD = fileASBD else {
            if state == .idle { throw MeetingPCMSinkError.notBegun }
            throw MeetingPCMSinkError.alreadyFinalizedOrCancelled
        }
        guard !poisoned else { throw MeetingPCMSinkError.finalizationVerificationFailed("sink is poisoned") }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            throw MeetingPCMSinkError.invalidSampleBuffer("invalid or unready sample buffer")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric, !pts.isIndefinite, pts.timescale > 0 else {
            throw MeetingPCMSinkError.invalidPresentationTime
        }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let incoming = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        else { throw MeetingPCMSinkError.invalidSampleBuffer("missing audio format description") }
        let incomingContract: MeetingPCMFormatContract
        do { incomingContract = try MeetingPCMFormatContract(formatDescription: desc) }
        catch {
            poisoned = true
            closeOpenFile()
            throw MeetingPCMSinkError.unsupportedClientFormat(error.localizedDescription)
        }
        guard incomingContract == format.contract else {
            poisoned = true
            closeOpenFile()
            throw MeetingPCMSinkError.formatMismatch(expected: format.contract.description, actual: incomingContract.description)
        }
        guard incoming.mSampleRate == format.rate,
              incoming.mChannelsPerFrame == format.channels,
              incoming.mBitsPerChannel == 32,
              (incoming.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              (incoming.mFormatFlags & kAudioFormatFlagIsSignedInteger) == 0
        else {
            poisoned = true
            closeOpenFile()
            throw MeetingPCMSinkError.formatMismatch(expected: format.contract.description, actual: Self.describe(incoming, layout: Self.layoutData(desc)))
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { throw MeetingPCMSinkError.invalidSampleBuffer("zero frames") }
        let list = try AudioList(sampleBuffer: sampleBuffer)
        let packed = try list.interleavedFloat32(frames: frames, channels: Int(format.channels), inputASBD: incoming)
        let expectedBytes = try Self.checkedMultiply(Int64(frames), Int64(expectedASBD.mBytesPerFrame))
        guard Int64(packed.count) == expectedBytes else { throw MeetingPCMSinkError.invalidSampleBuffer("packed size mismatch") }
        var packetCount = try Self.checkedUInt32(Int64(frames))
        let packetOffset = try Self.checkedInt64(writtenPackets)
        let byteCount = try Self.checkedUInt32(Int64(packed.count))
        let status = packed.withUnsafeBytes { bytes in
            AudioFileWritePackets(file, false, byteCount, nil, packetOffset, &packetCount, bytes.baseAddress!)
        }
        let actual = Int64(packetCount)
        guard status == noErr else { poisoned = true; closeOpenFile(); throw MeetingPCMSinkError.writeFailed(status) }
        guard actual == Int64(frames) else { poisoned = true; closeOpenFile(); throw MeetingPCMSinkError.shortWrite(expectedFrames: Int64(frames), writtenFrames: actual) }
        writtenPackets = try Self.checkedAdd(writtenPackets, actual)
        let duration = CMTime(seconds: Double(frames) / format.rate, preferredTimescale: 1_000_000_000)
        return MeetingPCMAppendReceipt(framesAccepted: Int64(frames), framesWritten: actual, presentationStart: pts, presentationDuration: duration)
    }

    func finalize() -> Result<MeetingPCMFinalization, MeetingPCMSinkError> {
        guard state == .open, let paths, let format else { return .failure(state == .idle ? .notBegun : .alreadyFinalizedOrCancelled) }
        guard !poisoned else { removePartialAndClose(); return .failure(.finalizationVerificationFailed("sink is poisoned")) }
        guard writtenPackets > 0 else { removePartialAndClose(); state = .cancelled; return .failure(.finalizationVerificationFailed("CAF contains no written frames")) }
        if let file = audioFile {
            let status = AudioFileClose(file); audioFile = nil
            guard status == noErr else { try? FileManager.default.removeItem(at: paths.partial); state = .cancelled; return .failure(.writeFailed(status)) }
        }
        do {
            let check = try Self.verify(paths.partial, format: format, expectedPackets: writtenPackets)
            let identity = try Self.identity(paths.partial)
            guard !FileManager.default.fileExists(atPath: paths.final.path) else { throw MeetingPCMSinkError.finalPathAlreadyExists(paths.final.path) }
            try Self.fullSync(paths.partial)
            let beforePublish = try Self.identity(paths.partial)
            guard beforePublish.dev == identity.dev, beforePublish.ino == identity.ino, beforePublish.size == identity.size else {
                throw MeetingPCMSinkError.finalizationVerificationFailed("staged file changed before publication")
            }
            guard renameatx_np(AT_FDCWD, paths.partial.path, AT_FDCWD, paths.final.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw MeetingPCMSinkError.finalPathAlreadyExists(paths.final.path) }
                throw MeetingPCMSinkError.underlyingFileError("atomic rename failed: errno \(errno)")
            }
            try Self.syncDirectory(paths.final.deletingLastPathComponent())
            state = .finalized
            return .success(MeetingPCMFinalization(relativeFilePath: try relativePath(paths.final), byteCount: check.bytes, sha256: check.hash,
                                                   sampleRate: check.rate, channelCount: check.channels, frameCount: check.frames))
        } catch let error as MeetingPCMSinkError {
            state = .cancelled; try? FileManager.default.removeItem(at: paths.partial); return .failure(error)
        } catch { state = .cancelled; try? FileManager.default.removeItem(at: paths.partial); return .failure(.underlyingFileError(error.localizedDescription)) }
    }

    func cancel() { guard state == .open || state == .idle else { return }; removePartialAndClose(); state = .cancelled }

    // MARK: Path / format helpers
    private func resolvePaths(_ relative: String) throws -> Paths {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), relative.hasSuffix(".caf") else { throw MeetingPCMSinkError.invalidRelativePath(relative) }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !components.last!.contains(".partial.") else { throw MeetingPCMSinkError.invalidRelativePath(relative) }
        try Self.rejectSymlink(sessionDirectory)
        var parent = sessionDirectory
        for component in components.dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: parent.path) { try Self.rejectSymlink(parent) }
            else { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]) }
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: nil) else { throw MeetingPCMSinkError.underlyingFileError("parent does not exist") }
            guard chmod(parent.path, mode_t(0o700)) == 0 else {
                throw MeetingPCMSinkError.underlyingFileError("could not set directory permissions: \(parent.path)")
            }
        }
        let final = parent.appendingPathComponent(components.last!)
        if FileManager.default.fileExists(atPath: final.path) { try Self.rejectSymlink(final); throw MeetingPCMSinkError.finalPathAlreadyExists(relative) }
        let partial = parent.appendingPathComponent(String(components.last!.dropLast(4)) + ".\(UUID().uuidString).partial.caf")
        if FileManager.default.fileExists(atPath: partial.path) { throw MeetingPCMSinkError.partialPathAlreadyExists(partial.path) }
        return Paths(final: final, partial: partial)
    }

    private static func rejectSymlink(_ url: URL) throws {
        var st = stat(); guard lstat(url.path, &st) == 0 else { if errno == ENOENT { return }; throw MeetingPCMSinkError.underlyingFileError("cannot inspect \(url.path)") }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw MeetingPCMSinkError.symlinkComponentRejected(url.path) }
    }

    private static func canonicalASBD(rate: Double, channels: UInt32) throws -> AudioStreamBasicDescription {
        let (bytes, overflow) = channels.multipliedReportingOverflow(by: 4)
        guard !overflow else { throw MeetingPCMSinkError.unsupportedClientFormat("channel byte size overflow") }
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                                    mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    // MARK: ABL and checked arithmetic
    private final class AudioList {
        let pointer: UnsafeMutablePointer<AudioBufferList>; let retained: CMBlockBuffer?
        init(sampleBuffer: CMSampleBuffer) throws {
            var size = 0
            let first = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
            guard first == noErr, size > 0 else { throw MeetingPCMSinkError.invalidSampleBuffer("ABL size unavailable") }
            pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment).assumingMemoryBound(to: AudioBufferList.self)
            var block: CMBlockBuffer?
            let second = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: pointer, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
            guard second == noErr else { pointer.deallocate(); throw MeetingPCMSinkError.invalidSampleBuffer("ABL unavailable") }
            retained = block
        }
        deinit { pointer.deallocate() }
        func interleavedFloat32(frames: Int, channels: Int, inputASBD: AudioStreamBasicDescription) throws -> Data {
            let buffers = UnsafeMutableAudioBufferListPointer(pointer)
            let nonInterleaved = (inputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            guard (nonInterleaved ? buffers.count == channels : buffers.count == 1), buffers.allSatisfy({ $0.mData != nil && $0.mNumberChannels == (nonInterleaved ? 1 : UInt32(channels)) }) else { throw MeetingPCMSinkError.invalidSampleBuffer("ABL topology mismatch") }
            let bytesPerChannel = try MeetingAudioFilePCMChunkSink.checkedMultiply(Int64(frames), 4)
            let expectedBytes = try MeetingAudioFilePCMChunkSink.checkedMultiply(bytesPerChannel, nonInterleaved ? 1 : Int64(channels))
            guard buffers.allSatisfy({ Int64($0.mDataByteSize) == expectedBytes }) else { throw MeetingPCMSinkError.invalidSampleBuffer("ABL byte count mismatch") }
            let count = try MeetingAudioFilePCMChunkSink.checkedMultiply(Int64(frames), Int64(channels))
            var output = Data(count: try Int(MeetingAudioFilePCMChunkSink.checkedMultiply(count, 4)))
            output.withUnsafeMutableBytes { out in
                let dst = out.baseAddress!.assumingMemoryBound(to: Float.self)
                if nonInterleaved {
                    let src = buffers.map { $0.mData!.assumingMemoryBound(to: Float.self) }
                    for frame in 0..<frames { for channel in 0..<channels { dst[frame * channels + channel] = src[channel][frame] } }
                } else {
                    let src = buffers[0].mData!.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(count) { dst[i] = src[i] }
                }
            }
            for value in output.withUnsafeBytes({ $0.bindMemory(to: Float.self) }) where !value.isFinite { throw MeetingPCMSinkError.nonFiniteSample }
            return output
        }
    }

    private static func checkedMultiply(_ a: Int64, _ b: Int64) throws -> Int64 { let (v, o) = a.multipliedReportingOverflow(by: b); if o || v < 0 { throw MeetingPCMSinkError.invalidSampleBuffer("integer overflow") }; return v }
    private static func checkedAdd(_ a: Int64, _ b: Int64) throws -> Int64 { let (v, o) = a.addingReportingOverflow(b); if o || v < 0 { throw MeetingPCMSinkError.invalidSampleBuffer("integer overflow") }; return v }
    private static func checkedUInt32(_ value: Int64) throws -> UInt32 { guard value >= 0, value <= Int64(UInt32.max) else { throw MeetingPCMSinkError.invalidSampleBuffer("packet count overflow") }; return UInt32(value) }
    private static func checkedInt64(_ value: Int64) throws -> Int64 { guard value >= 0 else { throw MeetingPCMSinkError.invalidSampleBuffer("negative packet offset") }; return value }

    // MARK: Verification / durability
    private struct Check { let bytes: Int64; let hash: String; let rate: Double; let channels: Int; let frames: Int64 }
    private static func verify(_ url: URL, format: Format, expectedPackets: Int64) throws -> Check {
        var file: AudioFileID?; let open = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file); guard open == noErr, let file else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF reopen failed") }; defer { AudioFileClose(file) }
        var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let canonical = try Self.canonicalASBD(rate: format.rate, channels: format.channels)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd) == noErr,
              asbd.mSampleRate == canonical.mSampleRate,
              asbd.mFormatID == canonical.mFormatID,
              asbd.mFormatFlags == canonical.mFormatFlags,
              asbd.mBytesPerPacket == canonical.mBytesPerPacket,
              asbd.mFramesPerPacket == canonical.mFramesPerPacket,
              asbd.mBytesPerFrame == canonical.mBytesPerFrame,
              asbd.mChannelsPerFrame == canonical.mChannelsPerFrame,
              asbd.mBitsPerChannel == canonical.mBitsPerChannel
        else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF ASBD mismatch") }
        let layout = try Self.fileLayout(file); guard layout == format.layout else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF channel layout mismatch") }
        var packets: Int64 = 0; size = UInt32(MemoryLayout<Int64>.size); guard AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr, packets == expectedPackets else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF packet count mismatch") }
        var bytesCount: Int64 = 0; size = UInt32(MemoryLayout<Int64>.size); guard AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &size, &bytesCount) == noErr else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF byte count unavailable") }
        let expectedBytes = try checkedMultiply(packets, Int64(asbd.mBytesPerFrame)); guard bytesCount == expectedBytes else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF data bytes mismatch") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path); let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? -1; guard actualSize > 0 else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF is empty") }
        var hasher = SHA256(); let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; while true { let data = try handle.read(upToCount: 1 << 20) ?? Data(); if data.isEmpty { break }; hasher.update(data: data) }
        return Check(bytes: actualSize, hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(), rate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), frames: packets)
    }
    private static func fileLayout(_ file: AudioFileID) throws -> Data? { var size: UInt32 = 0; let query = AudioFileGetPropertyInfo(file, kAudioFilePropertyChannelLayout, &size, nil); guard query == noErr else { return nil }; guard size > 0 else { return nil }; var data = Data(count: Int(size)); let status = data.withUnsafeMutableBytes { AudioFileGetProperty(file, kAudioFilePropertyChannelLayout, &size, $0.baseAddress!) }; guard status == noErr else { throw MeetingPCMSinkError.finalizationVerificationFailed("CAF layout read failed") }; return data }
    private static func identity(_ url: URL) throws -> Identity { var st = stat(); guard lstat(url.path, &st) == 0 else { throw MeetingPCMSinkError.finalizationVerificationFailed("staged file disappeared") }; return Identity(dev: st.st_dev, ino: st.st_ino, size: st.st_size) }
    private static func fullSync(_ url: URL) throws { let fd = open(url.path, O_RDONLY); guard fd >= 0 else { throw MeetingPCMSinkError.underlyingFileError("open for sync failed") }; defer { close(fd) }; guard fcntl(fd, F_FULLFSYNC) == 0 else { throw MeetingPCMSinkError.underlyingFileError("F_FULLFSYNC failed") } }
    private static func syncDirectory(_ url: URL) throws { let fd = open(url.path, O_RDONLY | O_DIRECTORY); guard fd >= 0 else { throw MeetingPCMSinkError.underlyingFileError("open parent for sync failed") }; defer { close(fd) }; guard fsync(fd) == 0 else { throw MeetingPCMSinkError.underlyingFileError("parent fsync failed") } }
    private static func layoutData(_ layout: AVAudioChannelLayout?) -> Data? { MeetingPCMFormatContract.layoutData(layout) }
    private static func layoutData(_ desc: CMFormatDescription) -> Data? { MeetingPCMFormatContract.layoutData(desc) }
    private static func describe(_ format: Format) -> String { "rate=\(format.rate), channels=\(format.channels), layoutBytes=\(format.layout?.count ?? 0)" }
    private static func describe(_ asbd: AudioStreamBasicDescription, layout: Data?) -> String { "rate=\(asbd.mSampleRate), channels=\(asbd.mChannelsPerFrame), flags=\(asbd.mFormatFlags), layoutBytes=\(layout?.count ?? 0)" }
    private func relativePath(_ url: URL) throws -> String { let root = sessionDirectory.path.hasSuffix("/") ? sessionDirectory.path : sessionDirectory.path + "/"; guard url.path.hasPrefix(root) else { throw MeetingPCMSinkError.finalizationVerificationFailed("published path escaped session") }; return String(url.path.dropFirst(root.count)) }
    private func closeOpenFile() { if let file = audioFile { AudioFileClose(file); audioFile = nil } }
    private func removePartialAndClose() { closeOpenFile(); if let partial = paths?.partial { try? FileManager.default.removeItem(at: partial) } }
}
