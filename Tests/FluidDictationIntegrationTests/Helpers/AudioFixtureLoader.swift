import AVFoundation
import Foundation

enum AudioFixtureLoader {
    enum LoaderError: LocalizedError {
        case fixtureNotFound(name: String, ext: String)
        case unsupportedAudio(String)

        var errorDescription: String? {
            switch self {
            case let .fixtureNotFound(name, ext):
                return "Audio fixture not found: \(name).\(ext)"
            case let .unsupportedAudio(message):
                return "Audio fixture could not be loaded/converted: \(message)"
            }
        }
    }

    /// Loads an audio fixture from the test bundle and converts it to 16kHz mono Float32 samples.
    static func load16kMonoFloatSamples(named name: String, ext: String) throws -> [Float] {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw LoaderError.fixtureNotFound(name: name, ext: ext)
        }

        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw LoaderError.unsupportedAudio("Could not create desired audio format (16kHz mono Float32).")
        }

        // Fast-path: already 16k mono float
        if inputFormat.sampleRate == desiredFormat.sampleRate,
           inputFormat.channelCount == desiredFormat.channelCount,
           inputFormat.commonFormat == desiredFormat.commonFormat
        {
            let buffer = try readAllFrames(file: inputFile, format: inputFormat)
            return try extractMonoFloatSamples(buffer: buffer)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: desiredFormat) else {
            throw LoaderError.unsupportedAudio("Could not create AVAudioConverter.")
        }

        let inputFrameCount = AVAudioFrameCount(inputFile.length)
        let ratio = desiredFormat.sampleRate / inputFormat.sampleRate
        let estimatedOutputFrames = max(1, AVAudioFrameCount(Double(inputFrameCount) * ratio) + 1)

        let inputBuffer = try readAllFrames(file: inputFile, format: inputFormat)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: estimatedOutputFrames) else {
            throw LoaderError.unsupportedAudio("Could not allocate output buffer.")
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw LoaderError.unsupportedAudio(conversionError.localizedDescription)
        }

        return try extractMonoFloatSamples(buffer: outputBuffer)
    }

    private static func readAllFrames(file: AVAudioFile, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameCount, 1)) else {
            throw LoaderError.unsupportedAudio("Could not allocate input buffer.")
        }
        try file.read(into: buffer)
        return buffer
    }

    private static func extractMonoFloatSamples(buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.format.channelCount == 1 else {
            throw LoaderError.unsupportedAudio("Expected mono audio after conversion, got \(buffer.format.channelCount) channels.")
        }
        guard let channelData = buffer.floatChannelData else {
            throw LoaderError.unsupportedAudio("Expected Float32 PCM data (floatChannelData was nil).")
        }

        let frames = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
    }

    /// Used to locate this test bundle reliably.
    private final class BundleToken {}
}
