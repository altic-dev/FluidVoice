import AVFoundation
import Foundation

enum LocalAPIAudioDecoder {
    struct PreparedAudio {
        let estimatedSamples: Int
        let requiresBufferedTranscription: Bool
    }

    static let sampleRate: Double = 16_000
    static let maxDurationSeconds: Double = 300
    private static let oggSniffBytes = 64 * 1024

    static func requiresBufferedTranscription(for fileURL: URL) throws -> Bool {
        try self.isOggOpusFile(at: fileURL)
    }

    static func prepareForTranscription(fileURL: URL) throws -> PreparedAudio {
        if try self.isOggOpusFile(at: fileURL) {
            try self.validateOggFileSize(at: fileURL)
            return PreparedAudio(
                estimatedSamples: try OggOpusDecoder.sampleCount(fromFileAt: fileURL),
                requiresBufferedTranscription: true
            )
        }
        return PreparedAudio(
            estimatedSamples: try self.validateDurationWithinLimitUsingAVFoundation(for: fileURL),
            requiresBufferedTranscription: false
        )
    }

    static func samples(from fileURL: URL) throws -> [Float] {
        if try self.isOggOpusFile(at: fileURL) {
            try self.validateOggFileSize(at: fileURL)
            return try self.oggOpusSamples(from: Data(contentsOf: fileURL, options: .mappedIfSafe))
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
        if try self.isOggOpusFile(at: fileURL) {
            try self.validateOggFileSize(at: fileURL)
            return try OggOpusDecoder.sampleCount(fromFileAt: fileURL)
        }
        return try self.validateDurationWithinLimitUsingAVFoundation(for: fileURL)
    }

    private static func validateDurationWithinLimitUsingAVFoundation(for fileURL: URL) throws -> Int {
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

    private static func isOggOpusFile(at fileURL: URL) throws -> Bool {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Audio path must reference a regular file."]
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return OggOpusDecoder.isOggOpus(try handle.read(upToCount: self.oggSniffBytes) ?? Data())
    }

    private static func validateOggFileSize(at fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize <= LocalAPI.maxRequestBytes else {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "Audio input exceeds the 25 MB API limit."]
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

    static func resampleOpusTo16k(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = sourceBuffer.floatChannelData else {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate an OGG/Opus audio buffer."]
            )
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            channelData[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        return try AudioBufferConverter.monoSamples(
            from: sourceBuffer,
            targetSampleRate: self.sampleRate
        )
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
        return try self.resampleOpusTo16k(OggOpusDecoder.samples(from: data))
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
