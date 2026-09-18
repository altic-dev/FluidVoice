import AudioToolbox
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

nonisolated enum MeetingAECPCMAdapter {
    static func extract(
        _ sampleBuffer: CMSampleBuffer,
        kind: MeetingAECInputKind,
        stream: MeetingAECStreamToken
    ) -> Result<MeetingAECPCMBlock, MeetingAECFailure> {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return .failure(.invalidSampleBuffer) }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric,
              CMTimeGetSeconds(presentationTime).isFinite
        else { return .failure(.invalidTimestamp) }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return .failure(.invalidSampleBuffer) }

        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate == Double(MeetingAECConstants.sampleRateHz),
              asbd.mChannelsPerFrame > 0,
              asbd.mChannelsPerFrame <= 32,
              asbd.mFramesPerPacket == 1,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              asbd.mBitsPerChannel == 32
        else {
            return asbd.mSampleRate == Double(MeetingAECConstants.sampleRateHz)
                ? .failure(.unsupportedFormat)
                : .failure(.unsupportedSampleRate)
        }

        let channels = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytesPerFrame = UInt32(MemoryLayout<Float>.size * (nonInterleaved ? 1 : channels))
        guard asbd.mBytesPerFrame == expectedBytesPerFrame,
              asbd.mBytesPerPacket == expectedBytesPerFrame
        else { return .failure(.unsupportedFormat) }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        guard duration.isValid, duration.isNumeric, duration > .zero else {
            return .failure(.invalidDuration)
        }
        let nominalDuration = Double(frameCount) / Double(MeetingAECConstants.sampleRateHz)
        let actualDuration = CMTimeGetSeconds(duration)
        guard actualDuration.isFinite,
              abs(actualDuration - nominalDuration) <= 1.5 / Double(MeetingAECConstants.sampleRateHz)
        else { return .failure(.invalidDuration) }

        var requiredSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        ) == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size
        else { return .failure(.invalidSampleBuffer) }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let audioBufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        ) == noErr
        else { return .failure(.invalidSampleBuffer) }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty,
              buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) == channels
        else { return .failure(.unsupportedFormat) }

        var mono = [Float](repeating: 0, count: frameCount)
        for buffer in buffers {
            let bufferChannels = Int(buffer.mNumberChannels)
            let expectedByteCount = frameCount * bufferChannels * MemoryLayout<Float>.size
            guard bufferChannels > 0,
                  Int(buffer.mDataByteSize) == expectedByteCount,
                  let data = buffer.mData
            else { return .failure(.invalidSampleBuffer) }
            let values = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                let base = frame * bufferChannels
                for channel in 0..<bufferChannels {
                    let value = values[base + channel]
                    guard value.isFinite else { return .failure(.nonFiniteSamples) }
                    mono[frame] += value
                }
            }
        }
        if channels > 1 {
            let divisor = Float(channels)
            for index in mono.indices { mono[index] /= divisor }
        }
        guard mono.allSatisfy(\.isFinite) else { return .failure(.nonFiniteSamples) }

        return .success(MeetingAECPCMBlock(
            kind: kind,
            stream: stream,
            presentationTime: presentationTime,
            duration: duration,
            samples: mono,
            sourceFormat: MeetingAECPCMFormat(
                channelCount: channels,
                interleaved: !nonInterleaved
            )
        ))
    }

    /// Produces an owning mono Float32 sample buffer. `presentationTime` is always the source
    /// capture PTS (plus an exact source-sample offset), never an output ordinal.
    static func synthesize(samples: [Float], presentationTime: CMTime) -> CMSampleBuffer? {
        guard !samples.isEmpty,
              samples.allSatisfy(\.isFinite),
              presentationTime.isValid,
              presentationTime.isNumeric,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(MeetingAECConstants.sampleRateHz),
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        return meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: presentationTime)
    }
}
