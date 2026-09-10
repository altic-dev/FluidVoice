import AVFoundation
import Foundation

enum LocalAPIAudioDecoder {
    static let sampleRate: Double = 16_000
    static let maxChunkDurationSeconds: Double = 20 * 60

    actor ChunkReader {
        private let audioFile: AVAudioFile
        private let sourceFramesPerChunk: AVAudioFrameCount

        init(
            fileURL: URL,
            chunkDurationSeconds: Double = LocalAPIAudioDecoder.maxChunkDurationSeconds
        ) throws {
            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: fileURL)
            } catch {
                throw LocalAPIAudioDecoder.audioDecodeError(underlying: error)
            }

            let sourceSampleRate = audioFile.processingFormat.sampleRate
            guard sourceSampleRate > 0, chunkDurationSeconds > 0 else {
                throw NSError(
                    domain: "LocalAPIAudioDecoder",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "Audio file has an invalid sample rate or chunk duration."]
                )
            }

            self.audioFile = audioFile
            self.sourceFramesPerChunk = AVAudioFrameCount(sourceSampleRate * chunkDurationSeconds)
        }

        func nextSamples() throws -> [Float] {
            guard self.audioFile.framePosition < self.audioFile.length else { return [] }

            let remainingFrames = self.audioFile.length - self.audioFile.framePosition
            let framesToRead = AVAudioFrameCount(min(
                AVAudioFramePosition(self.sourceFramesPerChunk),
                remainingFrames
            ))
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: self.audioFile.processingFormat,
                frameCapacity: framesToRead
            ) else {
                throw NSError(
                    domain: "LocalAPIAudioDecoder",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."]
                )
            }

            do {
                try self.audioFile.read(into: sourceBuffer, frameCount: framesToRead)
                return try AudioBufferConverter.monoSamples(
                    from: sourceBuffer,
                    targetSampleRate: LocalAPIAudioDecoder.sampleRate
                )
            } catch {
                let nsError = error as NSError
                if nsError.domain == "LocalAPIAudioDecoder" {
                    throw error
                }
                throw LocalAPIAudioDecoder.audioDecodeError(underlying: error)
            }
        }
    }

    static func temporaryFile(fromAudioData data: Data, suggestedExtension: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let trimmedExtension = suggestedExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
            let fileExtension = trimmedExtension.isEmpty ? "wav" : trimmedExtension
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fluidvoice-api-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        }.value
    }

    static func withTemporaryAudioFile<T>(
        fromAudioData data: Data,
        suggestedExtension: String,
        operation: (URL) async throws -> T
    ) async throws -> T {
        let fileURL = try await self.temporaryFile(
            fromAudioData: data,
            suggestedExtension: suggestedExtension
        )
        do {
            let result = try await operation(fileURL)
            await self.removeTemporaryFile(at: fileURL)
            return result
        } catch {
            await self.removeTemporaryFile(at: fileURL)
            throw error
        }
    }

    static func removeTemporaryFile(at fileURL: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: fileURL)
        }.value
    }

    static func estimatedSampleCount(for fileURL: URL) throws -> Int {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw self.audioDecodeError(underlying: error)
        }

        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw NSError(
                domain: "LocalAPIAudioDecoder",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Audio file has an invalid sample rate."]
            )
        }

        return Int((Double(file.length) * self.sampleRate / sourceFormat.sampleRate).rounded())
    }

    private static func audioDecodeError(underlying error: Error) -> NSError {
        NSError(
            domain: "LocalAPIAudioDecoder",
            code: -7,
            userInfo: [
                NSLocalizedDescriptionKey: "The uploaded file could not be decoded as audio.",
                NSUnderlyingErrorKey: error,
            ]
        )
    }
}
