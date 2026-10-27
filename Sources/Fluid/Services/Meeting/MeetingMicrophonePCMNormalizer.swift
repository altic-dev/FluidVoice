@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Adapts native microphone LPCM before the writer, echo processing and live captions fan out.
/// One converter is retained per producer, rebuilt only when its format changes. No resampling,
/// channel mixing, capture delay or opening-frame discard is involved.
final nonisolated class MeetingMicrophonePCMNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Invalid/unsupported input is returned intact so the existing writer still reports its
    /// failure and degraded health. Conversion must never silently discard a capture callback.
    func normalize(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample)
        else { return sample }
        if (try? MeetingPCMFormatContract(formatDescription: description)) != nil { return sample }
        return self.lock.withLock {
            (try? self.convert(sample, description: description)) ?? sample
        }
    }

    private func convert(_ sample: CMSampleBuffer, description: CMFormatDescription) throws -> CMSampleBuffer {
        let format = try MeetingPCMFormatResolver.resolve(description)
        let asbd = format.streamDescription.pointee
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(format.channelCount)
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              [16, 24, 32].contains(asbd.mBitsPerChannel),
              format.sampleRate.isFinite, format.sampleRate > 0,
              channels > 0, frames > 0,
              // Bound malformed callback metadata to at most 4 MiB of Float32 output.
              frames <= 1_048_576 / channels,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw MeetingPCMFormatContractError.unsupported("invalid native integer microphone buffer") }
        input.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
        ) == noErr else { throw MeetingPCMFormatContractError.unsupported("invalid microphone PCM payload") }

        if self.sourceFormat != format || self.converter == nil {
            let target: AVAudioFormat?
            if let layout = format.channelLayout {
                target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: true, channelLayout: layout)
            } else {
                target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: true)
            }
            guard let target, let converter = AVAudioConverter(from: format, to: target) else {
                throw MeetingPCMFormatContractError.unsupported("cannot convert microphone PCM")
            }
            self.sourceFormat = format
            self.converter = converter
        }
        guard let converter = self.converter,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: input.frameLength)
        else { throw MeetingPCMFormatContractError.unsupported("cannot allocate microphone PCM") }
        try converter.convert(to: output, from: input)
        guard output.frameLength == input.frameLength else {
            throw MeetingPCMFormatContractError.unsupported("incomplete microphone PCM conversion")
        }
        return try Self.makeSample(output, timingFrom: sample)
    }

    private static func makeSample(_ buffer: AVAudioPCMBuffer, timingFrom source: CMSampleBuffer) throws -> CMSampleBuffer {
        let audio = buffer.audioBufferList.pointee.mBuffers
        let byteCount = Int(audio.mDataByteSize)
        var block: CMBlockBuffer?
        guard let data = audio.mData,
              CMBlockBufferCreateWithMemoryBlock(
                  allocator: kCFAllocatorDefault,
                  memoryBlock: nil,
                  blockLength: byteCount,
                  blockAllocator: nil,
                  customBlockSource: nil,
                  offsetToData: 0,
                  dataLength: byteCount,
                  flags: kCMBlockBufferAssureMemoryNowFlag,
                  blockBufferOut: &block
              ) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == noErr
        else { throw MeetingPCMFormatContractError.unsupported("cannot own converted microphone PCM") }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(source, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0, count <= CMSampleBufferGetNumSamples(source)
        else { throw MeetingPCMFormatContractError.unsupported("invalid microphone timing") }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(source, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil) == noErr else {
            throw MeetingPCMFormatContractError.unsupported("cannot preserve microphone timing")
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: buffer.format.formatDescription,
            sampleCount: Int(buffer.frameLength),
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &result
        ) == noErr, let result else { throw MeetingPCMFormatContractError.unsupported("cannot create converted microphone sample") }
        if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: source, attachmentMode: kCMAttachmentMode_ShouldPropagate) {
            CMSetAttachments(result, attachments: attachments, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return result
    }
}
