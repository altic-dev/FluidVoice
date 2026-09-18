@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// The format identity shared by capture writers and PCM sinks. Channel topology is validated
/// but intentionally excluded from identity: the sink canonicalizes planar input into interleaved
/// CAF, so an interleaved/planar transition with the same semantic layout is one capture epoch.
nonisolated struct MeetingPCMFormatContract: Equatable, Sendable {
    nonisolated enum SemanticLayout: Equatable, Sendable {
        case mono
        case stereo
        case explicit(Data)
    }

    let sampleRate: Double
    let channelCount: Int
    let layout: SemanticLayout

    var description: String {
        let layoutDescription: String
        switch layout {
        case .mono: layoutDescription = "mono"
        case .stereo: layoutDescription = "stereo"
        case let .explicit(bytes): layoutDescription = "explicit(\(bytes.count) bytes)"
        }
        return "lpcm-f32 rate=\(sampleRate) channels=\(channelCount) layout=\(layoutDescription)"
    }

    init(audioFormat: AVAudioFormat) throws {
        try self.init(asbd: audioFormat.streamDescription.pointee, layoutData: Self.layoutData(audioFormat.channelLayout))
    }

    init(formatDescription: CMFormatDescription) throws {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw MeetingPCMFormatContractError.unsupported("missing LPCM stream description")
        }
        try self.init(asbd: asbd, layoutData: Self.layoutData(formatDescription))
    }

    init(asbd: AudioStreamBasicDescription, layoutData: Data?) throws {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0,
              asbd.mBitsPerChannel == 32,
              asbd.mFramesPerPacket == 1,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0
        else { throw MeetingPCMFormatContractError.unsupported("native Float32 LPCM required") }

        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if isNonInterleaved {
            guard asbd.mBytesPerFrame == 4, asbd.mBytesPerPacket == 4 else {
                throw MeetingPCMFormatContractError.unsupported("invalid planar Float32 byte layout")
            }
        } else {
            let expectedBytes = UInt64(asbd.mChannelsPerFrame) * 4
            guard UInt64(asbd.mBytesPerFrame) == expectedBytes,
                  UInt64(asbd.mBytesPerPacket) == expectedBytes else {
                throw MeetingPCMFormatContractError.unsupported("invalid interleaved Float32 byte layout")
            }
        }

        self.sampleRate = asbd.mSampleRate
        self.channelCount = Int(asbd.mChannelsPerFrame)
        self.layout = Self.semanticLayout(channelCount: self.channelCount, layoutData: layoutData)
    }

    private static func semanticLayout(channelCount: Int, layoutData: Data?) -> SemanticLayout {
        let tag = layoutData.flatMap { data -> UInt32? in
            guard data.count >= MemoryLayout<UInt32>.size else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        if channelCount == 1,
           tag == nil || tag == kAudioChannelLayoutTag_Mono ||
           tag == (kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)) {
            return .mono
        }
        if channelCount == 2,
           tag == nil || tag == kAudioChannelLayoutTag_Stereo {
            return .stereo
        }
        return .explicit(layoutData ?? Data())
    }

    static func layoutData(_ layout: AVAudioChannelLayout?) -> Data? {
        guard let layout else { return nil }
        let tag = layout.layout.pointee.mChannelLayoutTag
        let count = layout.layout.pointee.mNumberChannelDescriptions
        let headerSize = MemoryLayout<UInt32>.size * 3
        let size = tag != kAudioChannelLayoutTag_UseChannelDescriptions
            ? headerSize
            : headerSize + Int(count) * MemoryLayout<AudioChannelDescription>.stride
        return Data(bytes: layout.layout, count: size)
    }

    static func layoutData(_ desc: CMFormatDescription) -> Data? {
        var size = 0
        guard let ptr = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &size), size > 0 else { return nil }
        return Data(bytes: ptr, count: size)
    }
}

nonisolated enum MeetingPCMFormatContractError: Error, Equatable, Sendable {
    case unsupported(String)
}
