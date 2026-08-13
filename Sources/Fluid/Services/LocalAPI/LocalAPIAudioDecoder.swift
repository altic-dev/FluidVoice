import AVFoundation
import Foundation

enum LocalAPIAudioDecoder {
    static let sampleRate: Double = 16_000
    static let maxDurationSeconds: Double = 300

    static func requiresBufferedTranscription(for fileURL: URL) throws -> Bool {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return OggOpusDecoder.isOggOpus(data)
    }

    static func samples(from fileURL: URL) throws -> [Float] {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        if OggOpusDecoder.isOggOpus(data) {
            return try self.oggOpusSamples(from: data)
        }
        do {
            return try self.samplesUsingAVFoundation(from: fileURL)
        } catch {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported or invalid audio file: \(error.localizedDescription)"]
            )
        }
    }

    private static func samplesUsingAVFoundation(from fileURL: URL) throws -> [Float] {
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
        return try AudioBufferConverter.monoSamples(
            from: sourceBuffer,
            targetSampleRate: self.sampleRate
        )
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
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        if OggOpusDecoder.isOggOpus(data) {
            try self.validateRequestSize(data)
            return try OggOpusDecoder.sampleCount(from: data) / 3
        }
        do {
            let file = try AVAudioFile(forReading: fileURL)
            return try self.validateDurationWithinLimit(for: file)
        } catch {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported or invalid audio file: \(error.localizedDescription)"]
            )
        }
    }

    private static func validateDurationWithinLimit(for file: AVAudioFile) throws -> Int {
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

    private static func downsampleOpusTo16k(_ samples: [Float]) -> [Float] {
        guard samples.count >= 3 else { return [] }
        var output = [Float]()
        output.reserveCapacity(samples.count / 3)
        for index in stride(from: 0, through: samples.count - 3, by: 3) {
            output.append((samples[index] + samples[index + 1] + samples[index + 2]) / 3)
        }
        return output
    }

    static func oggOpusSamples(from data: Data) throws -> [Float] {
        try self.validateRequestSize(data)
        guard OggOpusDecoder.isOggOpus(data) else {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "Audio input is not an OGG/Opus stream."]
            )
        }
        return self.downsampleOpusTo16k(try OggOpusDecoder.samples(from: data))
    }

    private static func validateRequestSize(_ data: Data) throws {
        guard data.count <= LocalAPI.maxRequestBytes else {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "Audio input exceeds the 25 MB API limit."]
            )
        }
    }
}
