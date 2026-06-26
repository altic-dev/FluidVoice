import AVFoundation
import Foundation

enum LocalAPIAudioDecoder {
    static let sampleRate: Double = 16_000
    static let maxDurationSeconds: Double = 300

    static func samples(from fileURL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        let maxFrames = AVAudioFramePosition(sourceFormat.sampleRate * self.maxDurationSeconds)
        let framesToRead = min(file.length, maxFrames)
        guard framesToRead > 0 else { return [] }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(framesToRead)
        ) else {
            throw NSError(domain: "LocalAPIAudioDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."])
        }

        try file.read(into: sourceBuffer, frameCount: AVAudioFrameCount(framesToRead))
        return try self.convertToMono16k(sourceBuffer)
    }

    static func samples(fromAudioData data: Data, suggestedExtension: String) throws -> [Float] {
        let ext = suggestedExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t")).isEmpty
            ? "wav"
            : suggestedExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-api-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try self.samples(from: url)
    }

    static func validateDurationWithinLimit(for fileURL: URL) throws -> Int {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw NSError(domain: "LocalAPIAudioDecoder", code: -6, userInfo: [NSLocalizedDescriptionKey: "Audio file has an invalid sample rate."])
        }

        let maxFrames = AVAudioFramePosition(sourceFormat.sampleRate * self.maxDurationSeconds)
        guard file.length <= maxFrames else {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Audio file exceeds the \(Int(self.maxDurationSeconds)) second API limit."]
            )
        }

        return Int((Double(file.length) * self.sampleRate / sourceFormat.sampleRate).rounded())
    }

    private static func convertToMono16k(_ sourceBuffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "LocalAPIAudioDecoder", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unable to create target audio format."])
        }

        guard sourceBuffer.format != targetFormat else {
            guard let channel = sourceBuffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(sourceBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            throw NSError(domain: "LocalAPIAudioDecoder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to convert audio to 16 kHz mono."])
        }

        let ratio = self.sampleRate / sourceBuffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw NSError(domain: "LocalAPIAudioDecoder", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate converted audio buffer."])
        }

        var consumedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumedInput {
                status.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            status.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard let channel = outputBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}
