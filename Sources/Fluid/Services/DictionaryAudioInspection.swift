// nil means an invalid cut, not a zero-length embedding.
import Foundation

/// Bounded local diagnostic evidence. Never used to change production matching.
nonisolated struct DictionaryAudioInspection: Codable, Equatable, Sendable {
    struct Frames: Codable, Equatable, Sendable {
        let offset: Double
        let frameDuration: Double
        let hiddenSize: Int
        let values: [Float]
        var count: Int { self.hiddenSize > 0 ? self.values.count / self.hiddenSize : 0 }
    }

    struct Word: Codable, Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    let samples: [Float] // Exact 16 kHz model input, including any minimum-length padding.
    var recordedSampleCount: Int
    let frames: [Frames]
    let words: [Word]
    let selectedStart: Double
    let selectedEnd: Double
    var duration: Double { Double(self.recordedSampleCount) / 16_000 }
    var paddedDuration: Double { Double(self.samples.count) / 16_000 }

    var isValid: Bool {
        guard !self.samples.isEmpty, self.samples.count <= 16_000 * 120,
              self.recordedSampleCount > 0, self.recordedSampleCount <= self.samples.count,
              self.samples.allSatisfy(\.isFinite), self.frames.count <= 9, !self.frames.isEmpty,
              self.selectedStart.isFinite, self.selectedEnd.isFinite,
              self.selectedStart >= 0, self.selectedStart < self.selectedEnd,
              self.selectedEnd <= self.paddedDuration + 0.081
        else { return false }
        var previousEnd = 0.0
        for frame in self.frames {
            guard frame.offset.isFinite, frame.offset >= previousEnd - 0.081,
                  frame.frameDuration == 0.08, frame.hiddenSize > 0, frame.hiddenSize <= 2048,
                  frame.values.count % frame.hiddenSize == 0, !frame.values.isEmpty, frame.count <= 190,
                  frame.values.allSatisfy(\.isFinite),
                  frame.offset + Double(frame.count) * frame.frameDuration <= self.paddedDuration + 0.081
            else { return false }
            previousEnd = frame.offset + Double(frame.count) * frame.frameDuration
        }
        return true
    }

    // Uses one encoder pass and the same mean/L2 operation as the matcher.
    // Crossing separately encoded chunks is deliberately unavailable.
    // swiftlint:disable:next discouraged_optional_collection
    func embedding(start: Double, end: Double) -> [Float]? {
        guard start.isFinite, end.isFinite, start >= 0, start < end else { return nil }
        guard let chunk = self.frames.first(where: {
            start >= $0.offset - 0.001 && end <= $0.offset + Double($0.count) * $0.frameDuration + 0.001
        }), chunk.hiddenSize > 0 else { return nil }
        let lower = max(0, Int(((start - chunk.offset) / chunk.frameDuration).rounded()))
        let upper = min(chunk.count, Int(((end - chunk.offset) / chunk.frameDuration).rounded()))
        guard lower < upper else { return nil }
        var mean = [Float](repeating: 0, count: chunk.hiddenSize)
        for frame in lower..<upper {
            for index in mean.indices {
                mean[index] += chunk.values[frame * chunk.hiddenSize + index]
            }
        }
        let norm = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return mean.map { $0 / norm }
    }

    // swiftlint:disable:next discouraged_optional_collection
    static func similarity(_ first: [Float]?, _ second: [Float]?) -> Float? {
        guard let first, let second, !first.isEmpty, first.count == second.count else { return nil }
        let firstNorm = sqrt(first.reduce(Float(0)) { $0 + $1 * $1 })
        let secondNorm = sqrt(second.reduce(Float(0)) { $0 + $1 * $1 })
        guard firstNorm > 0, secondNorm > 0 else { return nil }
        let value = zip(first, second).reduce(Float(0)) { $0 + $1.0 * $1.1 } / (firstNorm * secondNorm)
        return value.isFinite ? value : nil
    }
}

nonisolated struct DictionaryAudioCut: Equatable, Sendable {
    var start: Double
    var end: Double
}

nonisolated struct DictionaryAudioCutMetrics: Sendable {
    let leadingQuiet: Double
    let trailingQuiet: Double
    let suggested: DictionaryAudioCut?
}

/// CPU-only operations are isolated from SwiftUI and never load an ASR model.
actor DictionaryAudioInspector {
    static let shared = DictionaryAudioInspector()

    func waveform(_ audio: DictionaryAudioInspection) -> [Float] {
        let count = min(audio.recordedSampleCount, audio.samples.count)
        guard count > 0 else { return [] }
        let stride = max(1, (count + 255) / 256)
        return Swift.stride(from: 0, to: count, by: stride).map { start in
            audio.samples[start..<min(count, start + stride)].reduce(Float(0)) { max($0, abs($1)) }
        }
    }

    func metrics(_ audio: DictionaryAudioInspection, cut: DictionaryAudioCut) -> DictionaryAudioCutMetrics {
        let lower = max(0, min(audio.recordedSampleCount, Int(cut.start * 16_000)))
        let upper = max(lower, min(audio.recordedSampleCount, Int(cut.end * 16_000)))
        let blocks = Array(stride(from: lower, to: upper, by: 320)) // 20 ms RMS, -45 dBFS.
        let active = blocks.filter { start in
            let block = audio.samples[start..<min(upper, start + 320)]
            let rms = sqrt(block.reduce(Float(0)) { $0 + $1 * $1 } / Float(block.count))
            return rms >= 0.005_623_413
        }
        guard let first = active.first, let last = active.last else {
            return DictionaryAudioCutMetrics(leadingQuiet: Double(upper - lower) / 16_000, trailingQuiet: 0, suggested: nil)
        }
        let leading = Double(first - lower) / 16_000
        let trailing = Double(max(0, upper - last - 320)) / 16_000
        // Keep 80 ms of context; this is an optional comparison, never an automatic edit.
        let start = max(cut.start, floor((Double(first) / 16_000 - 0.08) / 0.08) * 0.08)
        let end = min(cut.end, ceil((Double(last + 320) / 16_000 + 0.08) / 0.08) * 0.08)
        return DictionaryAudioCutMetrics(leadingQuiet: leading, trailingQuiet: trailing, suggested: start < end ? DictionaryAudioCut(start: start, end: end) : nil)
    }

    func score(test: DictionaryAudioInspection, testCut: DictionaryAudioCut, reference: DictionaryAudioInspection?, referenceCut: DictionaryAudioCut?, storedVector: [Float]) -> Float? {
        // swiftlint:disable:next discouraged_optional_collection
        let target: [Float]?
        if let reference, let referenceCut {
            target = reference.embedding(start: referenceCut.start, end: referenceCut.end)
        } else { target = storedVector }
        return DictionaryAudioInspection.similarity(test.embedding(start: testCut.start, end: testCut.end), target)
    }

    /// One fixed test vector compared with every enrollment, preserving enrollment order.
    func scores(test: DictionaryAudioInspection, testCut: DictionaryAudioCut, references: [DictionaryAudioInspection?], referenceCuts: [DictionaryAudioCut?], storedVectors: [[Float]]) -> [Float?] {
        let vector = test.embedding(start: testCut.start, end: testCut.end)
        return storedVectors.indices.map { index in
            if references.indices.contains(index), referenceCuts.indices.contains(index),
               let reference = references[index], let cut = referenceCuts[index]
            {
                return DictionaryAudioInspection.similarity(vector, reference.embedding(start: cut.start, end: cut.end))
            }
            return DictionaryAudioInspection.similarity(vector, storedVectors[index])
        }
    }

    func wav(_ audio: DictionaryAudioInspection, cut: DictionaryAudioCut?) throws -> Data {
        let start = max(0, min(audio.recordedSampleCount, Int((cut?.start ?? 0) * 16_000)))
        let end = min(audio.recordedSampleCount, Int((cut?.end ?? audio.duration) * 16_000))
        guard start < end else { throw DictionaryMatchPlaygroundError.unavailable("This selection has no recorded audio.") }
        var pcm = Data(capacity: (end - start) * 2)
        for value in audio.samples[start..<end] {
            var sample = Int16(max(-1, min(1, value)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000))
        append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

// Compact Float32 blobs avoid serializing millions of boxed floating-point values.
// Supported Macs are little-endian; the stored format is explicitly versioned.
extension DictionaryAudioInspection {
    private enum CodingKeys: String, CodingKey {
        case version, samples, recordedSampleCount, frames, words, selectedStart, selectedEnd
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported inspection format")
        }
        self.samples = try Self.floats(from: values.decode(Data.self, forKey: .samples))
        self.recordedSampleCount = try values.decode(Int.self, forKey: .recordedSampleCount)
        self.frames = try values.decode([Frames].self, forKey: .frames)
        self.words = try values.decode([Word].self, forKey: .words)
        self.selectedStart = try values.decode(Double.self, forKey: .selectedStart)
        self.selectedEnd = try values.decode(Double.self, forKey: .selectedEnd)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(self.samples.withUnsafeBytes { Data($0) }, forKey: .samples)
        try values.encode(self.recordedSampleCount, forKey: .recordedSampleCount)
        try values.encode(self.frames, forKey: .frames)
        try values.encode(self.words, forKey: .words)
        try values.encode(self.selectedStart, forKey: .selectedStart)
        try values.encode(self.selectedEnd, forKey: .selectedEnd)
    }

    private static func floats(from data: Data) throws -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0, data.count <= 8_000_000 else {
            throw DictionaryMatchPlaygroundError.unavailable("Invalid inspection audio or encoder data.")
        }
        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { destination in data.copyBytes(to: destination) }
        return values
    }
}

extension DictionaryAudioInspection.Frames {
    private enum CodingKeys: String, CodingKey { case offset, frameDuration, hiddenSize, values }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.offset = try container.decode(Double.self, forKey: .offset)
        self.frameDuration = try container.decode(Double.self, forKey: .frameDuration)
        self.hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        self.values = try DictionaryAudioInspection.floats(from: container.decode(Data.self, forKey: .values))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.offset, forKey: .offset)
        try container.encode(self.frameDuration, forKey: .frameDuration)
        try container.encode(self.hiddenSize, forKey: .hiddenSize)
        try container.encode(self.values.withUnsafeBytes { Data($0) }, forKey: .values)
    }
}
