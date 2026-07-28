import AVFoundation
import Foundation

enum AudioBufferConverter {
    enum ConversionError: LocalizedError {
        case invalidSourceFormat
        case invalidTargetSampleRate
        case inaccessibleChannelData
        case targetFormatCreationFailed
        case converterCreationFailed
        case outputBufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .invalidSourceFormat:
                return "Audio buffer has an invalid sample rate or channel count."
            case .invalidTargetSampleRate:
                return "Target audio sample rate must be greater than zero."
            case .inaccessibleChannelData:
                return "Could not access Float32 audio channel data."
            case .targetFormatCreationFailed:
                return "Could not create the target mono audio format."
            case .converterCreationFailed:
                return "Could not create an audio converter."
            case .outputBufferAllocationFailed:
                return "Could not allocate the converted audio buffer."
            }
        }
    }

    static func monoSamples(
        from buffer: AVAudioPCMBuffer,
        targetSampleRate: Double
    ) throws -> [Float] {
        let sourceFormat = buffer.format
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw ConversionError.invalidSourceFormat
        }
        guard targetSampleRate.isFinite, targetSampleRate > 0 else {
            throw ConversionError.invalidTargetSampleRate
        }
        guard buffer.frameLength > 0 else { return [] }

        if sourceFormat.sampleRate == targetSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32
        {
            guard let channelData = buffer.floatChannelData else {
                throw ConversionError.inaccessibleChannelData
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ConversionError.targetFormatCreationFailed
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ConversionError.converterCreationFailed
        }

        converter.downmix = sourceFormat.channelCount > 1

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let estimatedFrameCount = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(estimatedFrameCount, 1) + 1024
        ) else {
            throw ConversionError.outputBufferAllocationFailed
        }

        var conversionError: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if inputConsumed {
                status.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }
        guard let channelData = outputBuffer.floatChannelData else {
            throw ConversionError.inaccessibleChannelData
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
